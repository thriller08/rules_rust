"""Rules for Cargo build scripts (`build.rs` files)"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("//rust:defs.bzl", "rust_common")
load("//rust:rust_common.bzl", "BuildInfo")

# buildifier: disable=bzl-visibility
load(
    "//rust/private:rustc.bzl",
    "get_compilation_mode_opts",
    "get_linker_and_args",
)

# buildifier: disable=bzl-visibility
load(
    "//rust/private:utils.bzl",
    "dedent",
    "expand_dict_value_locations",
    "find_cc_toolchain",
    "find_toolchain",
    _name_to_crate_name = "name_to_crate_name",
)

# Reexport for cargo_build_script_wrapper.bzl
name_to_crate_name = _name_to_crate_name

CargoBuildScriptRunfilesInfo = provider(
    doc = "Info about a `cargo_build_script.script` target.",
    fields = {
        "data": "List[Target]: The raw `cargo_build_script_runfiles.data` attribute.",
        "tools": "List[Target]: The raw `cargo_build_script_runfiles.tools` attribute.",
    },
)

def _cargo_build_script_runfiles_impl(ctx):
    script = ctx.executable.script

    is_windows = script.extension == "exe"
    exe = ctx.actions.declare_file("{}{}".format(ctx.label.name, ".exe" if is_windows else ""))
    ctx.actions.symlink(
        output = exe,
        target_file = script,
        is_executable = True,
    )

    # Tools are ommitted here because they should be within the `script`
    # attribute's runfiles.
    runfiles = ctx.runfiles(files = ctx.files.data)

    return [
        DefaultInfo(
            files = depset([exe]),
            runfiles = runfiles.merge(ctx.attr.script[DefaultInfo].default_runfiles),
            executable = exe,
        ),
        CargoBuildScriptRunfilesInfo(
            data = ctx.attr.data,
            tools = ctx.attr.tools,
        ),
    ]

cargo_build_script_runfiles = rule(
    doc = """\
A rule for producing `cargo_build_script.script` with proper runfiles.

This rule ensure's the executable for `cargo_build_script` has properly formed runfiles with `cfg=target` and
`cfg=exec` files. This is a challenge becuase had the script binary been directly consumed, it would have been
in either configuration which would have been incorrect for either the `tools` (exec) or `data` (target) attributes.
This is solved here by consuming the script as exec and creating a symlink to consumers of this rule can consume
with `cfg=target` and still get an exec compatible binary.

This rule may not be necessary if it becomes possible to construct runfiles trees within a rule for an action as
we'd be able to build the correct runfiles tree and configure the script runner to run the script in the new runfiles
directory:
https://github.com/bazelbuild/bazel/issues/15486
""",
    implementation = _cargo_build_script_runfiles_impl,
    attrs = {
        "data": attr.label_list(
            doc = "Data required by the build script.",
            allow_files = True,
        ),
        "script": attr.label(
            doc = "The binary script to run, generally a `rust_binary` target.",
            executable = True,
            mandatory = True,
            providers = [rust_common.crate_info],
            cfg = "exec",
        ),
        "tools": attr.label_list(
            doc = "Tools required by the build script.",
            allow_files = True,
            cfg = "exec",
        ),
    },
    executable = True,
)

def get_cc_compile_args_and_env(cc_toolchain, feature_configuration):
    """Gather cc environment variables from the given `cc_toolchain`

    Args:
        cc_toolchain (cc_toolchain): The current rule's `cc_toolchain`.
        feature_configuration (FeatureConfiguration): Class used to construct command lines from CROSSTOOL features.

    Returns:
        tuple: A tuple of the following items:
            - (sequence): A flattened C command line flags for given action.
            - (sequence): A flattened CXX command line flags for given action.
            - (dict): C environment variables to be set for given action.
    """
    compile_variables = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
    )
    cc_c_args = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.c_compile,
        variables = compile_variables,
    )
    cc_cxx_args = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.cpp_compile,
        variables = compile_variables,
    )
    cc_env = cc_common.get_environment_variables(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.c_compile,
        variables = compile_variables,
    )
    return cc_c_args, cc_cxx_args, cc_env

def _pwd_flags_sysroot(args):
    """Prefix execroot-relative paths of known arguments with ${pwd}.

    Args:
        args (list): List of tool arguments.

    Returns:
        list: The modified argument list.
    """
    res = []
    for arg in args:
        s, opt, path = arg.partition("--sysroot=")
        if s == "" and not paths.is_absolute(path):
            res.append("{}${{pwd}}/{}".format(opt, path))
        else:
            res.append(arg)
    return res

def _pwd_flags_isystem(args):
    """Prefix execroot-relative paths of known arguments with ${pwd}.

    Args:
        args (list): List of tool arguments.

    Returns:
        list: The modified argument list.
    """
    res = []
    fix_next_arg = False
    for arg in args:
        if fix_next_arg and not paths.is_absolute(arg):
            res.append("${{pwd}}/{}".format(arg))
        else:
            res.append(arg)

        fix_next_arg = arg == "-isystem"

    return res

def _pwd_flags(args):
    return _pwd_flags_isystem(_pwd_flags_sysroot(args))

def _feature_enabled(ctx, feature_name, default = False):
    """Check if a feature is enabled.

    If the feature is explicitly enabled or disabled, return accordingly.

    In the case where the feature is not explicitly enabled or disabled, return the default value.

    Args:
        ctx: The context object.
        feature_name: The name of the feature.
        default: The default value to return if the feature is not explicitly enabled or disabled.

    Returns:
        Boolean defining whether the feature is enabled.
    """
    if feature_name in ctx.disabled_features:
        return False

    if feature_name in ctx.features:
        return True

    return default

def _cargo_build_script_impl(ctx):
    """The implementation for the `cargo_build_script` rule.

    Args:
        ctx (ctx): The rules context object

    Returns:
        list: A list containing a BuildInfo provider
    """
    script = ctx.executable.script
    toolchain = find_toolchain(ctx)
    out_dir = ctx.actions.declare_directory(ctx.label.name + ".out_dir")
    env_out = ctx.actions.declare_file(ctx.label.name + ".env")
    dep_env_out = ctx.actions.declare_file(ctx.label.name + ".depenv")
    flags_out = ctx.actions.declare_file(ctx.label.name + ".flags")
    link_flags = ctx.actions.declare_file(ctx.label.name + ".linkflags")
    link_search_paths = ctx.actions.declare_file(ctx.label.name + ".linksearchpaths")  # rustc-link-search, propagated from transitive dependencies
    manifest_dir = "%s.runfiles/%s/%s" % (script.path, ctx.label.workspace_name or ctx.workspace_name, ctx.label.package)
    compilation_mode_opt_level = get_compilation_mode_opts(ctx, toolchain).opt_level

    streams = struct(
        stdout = ctx.actions.declare_file(ctx.label.name + ".stdout.log"),
        stderr = ctx.actions.declare_file(ctx.label.name + ".stderr.log"),
    )

    pkg_name = ctx.attr.pkg_name
    if pkg_name == "":
        pkg_name = name_to_pkg_name(ctx.label.name)

    toolchain_tools = [toolchain.all_files]

    cc_toolchain = find_cpp_toolchain(ctx)

    # Start with the default shell env, which contains any --action_env
    # settings passed in on the command line.
    env = dict(ctx.configuration.default_shell_env)

    env.update({
        "CARGO_CRATE_NAME": name_to_crate_name(pkg_name),
        "CARGO_MANIFEST_DIR": manifest_dir,
        "CARGO_PKG_NAME": pkg_name,
        "HOST": toolchain.exec_triple.str,
        "NUM_JOBS": "1",
        "OPT_LEVEL": compilation_mode_opt_level,
        "RUSTC": toolchain.rustc.path,
        "TARGET": toolchain.target_flag_value,
        # OUT_DIR is set by the runner itself, rather than on the action.
    })

    # This isn't exactly right, but Bazel doesn't have exact views of "debug" and "release", so...
    env.update({
        "DEBUG": {"dbg": "true", "fastbuild": "true", "opt": "false"}.get(ctx.var["COMPILATION_MODE"], "true"),
        "PROFILE": {"dbg": "debug", "fastbuild": "debug", "opt": "release"}.get(ctx.var["COMPILATION_MODE"], "unknown"),
    })

    if ctx.attr.version:
        version = ctx.attr.version.split("+")[0].split(".")
        patch = version[2].split("-") if len(version) > 2 else [""]
        env["CARGO_PKG_VERSION_MAJOR"] = version[0]
        env["CARGO_PKG_VERSION_MINOR"] = version[1] if len(version) > 1 else ""
        env["CARGO_PKG_VERSION_PATCH"] = patch[0]
        env["CARGO_PKG_VERSION_PRE"] = patch[1] if len(patch) > 1 else ""
        env["CARGO_PKG_VERSION"] = ctx.attr.version

    # Pull in env vars which may be required for the cc_toolchain to work (e.g. on OSX, the SDK version).
    # We hope that the linker env is sufficient for the whole cc_toolchain.
    cc_toolchain, feature_configuration = find_cc_toolchain(ctx)
    linker, link_args, linker_env = get_linker_and_args(ctx, ctx.attr, "bin", cc_toolchain, feature_configuration, None)
    env.update(**linker_env)
    env["LD"] = linker
    env["LDFLAGS"] = " ".join(_pwd_flags(link_args))

    # MSVC requires INCLUDE to be set
    cc_c_args, cc_cxx_args, cc_env = get_cc_compile_args_and_env(cc_toolchain, feature_configuration)
    include = cc_env.get("INCLUDE")
    if include:
        env["INCLUDE"] = include

    if cc_toolchain:
        toolchain_tools.append(cc_toolchain.all_files)

        env["CC"] = cc_common.get_tool_for_action(
            feature_configuration = feature_configuration,
            action_name = ACTION_NAMES.c_compile,
        )
        env["CXX"] = cc_common.get_tool_for_action(
            feature_configuration = feature_configuration,
            action_name = ACTION_NAMES.cpp_compile,
        )
        env["AR"] = cc_common.get_tool_for_action(
            feature_configuration = feature_configuration,
            action_name = ACTION_NAMES.cpp_link_static_library,
        )

        # Populate CFLAGS and CXXFLAGS that cc-rs relies on when building from source, in particular
        # to determine the deployment target when building for apple platforms (`macosx-version-min`
        # for example, itself derived from the `macos_minimum_os` Bazel argument).
        env["CFLAGS"] = " ".join(_pwd_flags(cc_c_args))
        env["CXXFLAGS"] = " ".join(_pwd_flags(cc_cxx_args))

    # Inform build scripts of rustc flags
    # https://github.com/rust-lang/cargo/issues/9600
    env["CARGO_ENCODED_RUSTFLAGS"] = "\\x1f".join([
        # Allow build scripts to locate the generated sysroot
        "--sysroot=${{pwd}}/{}".format(toolchain.sysroot),
    ] + ctx.attr.rustc_flags)

    for f in ctx.attr.crate_features:
        env["CARGO_FEATURE_" + f.upper().replace("-", "_")] = "1"

    links = ctx.attr.links or ""
    if links:
        env["CARGO_MANIFEST_LINKS"] = links

    # Add environment variables from the Rust toolchain.
    env.update(toolchain.env)

    # Gather data from the `toolchains` attribute.
    for target in ctx.attr.toolchains:
        if DefaultInfo in target:
            toolchain_tools.extend([
                target[DefaultInfo].files,
                target[DefaultInfo].default_runfiles.files,
            ])
        if platform_common.ToolchainInfo in target:
            all_files = getattr(target[platform_common.ToolchainInfo], "all_files", depset([]))
            if type(all_files) == "list":
                all_files = depset(all_files)
            toolchain_tools.append(all_files)
        if platform_common.TemplateVariableInfo in target:
            variables = getattr(target[platform_common.TemplateVariableInfo], "variables", depset([]))
            env.update(variables)

    script_info = ctx.attr.script[CargoBuildScriptRunfilesInfo]

    _merge_env_dict(env, expand_dict_value_locations(
        ctx,
        ctx.attr.build_script_env,
        getattr(ctx.attr, "data", []) +
        getattr(ctx.attr, "compile_data", []) +
        getattr(ctx.attr, "tools", []) +
        script_info.data +
        script_info.tools,
    ))

    script_tools = []
    script_data = []
    for target in script_info.data:
        script_data.append(target[DefaultInfo].files)
        script_data.append(target[DefaultInfo].default_runfiles.files)
    for target in script_info.tools:
        script_tools.append(target[DefaultInfo].files)
        script_tools.append(target[DefaultInfo].default_runfiles.files)

    tools = depset(
        direct = [
            script,
            ctx.executable._cargo_build_script_runner,
        ] + ([toolchain.target_json] if toolchain.target_json else []),
        transitive = script_data + script_tools + toolchain_tools,
    )

    # dep_env_file contains additional environment variables coming from
    # direct dependency sys-crates' build scripts. These need to be made
    # available to the current crate build script.
    # See https://doc.rust-lang.org/cargo/reference/build-scripts.html#-sys-packages
    # for details.
    args = ctx.actions.args()
    args.add(script)
    args.add(links)
    args.add(out_dir.path)
    args.add(env_out)
    args.add(flags_out)
    args.add(link_flags)
    args.add(link_search_paths)
    args.add(dep_env_out)
    args.add(streams.stdout)
    args.add(streams.stderr)
    args.add(ctx.attr.rundir)

    build_script_inputs = []
    for dep in ctx.attr.link_deps:
        if rust_common.dep_info in dep and dep[rust_common.dep_info].dep_env:
            dep_env_file = dep[rust_common.dep_info].dep_env
            args.add(dep_env_file.path)
            build_script_inputs.append(dep_env_file)
            for dep_build_info in dep[rust_common.dep_info].transitive_build_infos.to_list():
                build_script_inputs.append(dep_build_info.out_dir)

    for dep in ctx.attr.deps:
        for dep_build_info in dep[rust_common.dep_info].transitive_build_infos.to_list():
            build_script_inputs.append(dep_build_info.out_dir)

    experimental_symlink_execroot = ctx.attr._experimental_symlink_execroot[BuildSettingInfo].value or \
                                    _feature_enabled(ctx, "symlink-exec-root")

    if experimental_symlink_execroot:
        env["RULES_RUST_SYMLINK_EXEC_ROOT"] = "1"

    ctx.actions.run(
        executable = ctx.executable._cargo_build_script_runner,
        arguments = [args],
        outputs = [
            out_dir,
            env_out,
            flags_out,
            link_flags,
            link_search_paths,
            dep_env_out,
            streams.stdout,
            streams.stderr,
        ],
        tools = tools,
        inputs = build_script_inputs,
        mnemonic = "CargoBuildScriptRun",
        progress_message = "Running Cargo build script {}".format(pkg_name),
        env = env,
        toolchain = None,
        # Set use_default_shell_env so that $PATH is set, as tools like Cmake
        # may want to probe $PATH for helper tools.
        use_default_shell_env = True,
    )

    return [
        # Although this isn't used anywhere, without this, `bazel build`'ing
        # the cargo_build_script label won't actually run the build script
        # since bazel is lazy.
        DefaultInfo(files = depset([out_dir])),
        BuildInfo(
            out_dir = out_dir,
            rustc_env = env_out,
            dep_env = dep_env_out,
            flags = flags_out,
            linker_flags = link_flags,
            link_search_paths = link_search_paths,
            compile_data = depset(),
        ),
        OutputGroupInfo(
            streams = depset([streams.stdout, streams.stderr]),
            out_dir = depset([out_dir]),
        ),
    ]

cargo_build_script = rule(
    doc = (
        "A rule for running a crate's `build.rs` files to generate build information " +
        "which is then used to determine how to compile said crate."
    ),
    implementation = _cargo_build_script_impl,
    attrs = {
        "build_script_env": attr.string_dict(
            doc = "Environment variables for build scripts.",
        ),
        "crate_features": attr.string_list(
            doc = "The list of rust features that the build script should consider activated.",
        ),
        "deps": attr.label_list(
            doc = "The Rust build-dependencies of the crate",
            providers = [rust_common.dep_info],
            cfg = "exec",
        ),
        "link_deps": attr.label_list(
            doc = dedent("""\
                The subset of the Rust (normal) dependencies of the crate that
                have the links attribute and therefore provide environment
                variables to this build script.
            """),
            providers = [rust_common.dep_info],
        ),
        "links": attr.string(
            doc = "The name of the native library this crate links against.",
        ),
        "pkg_name": attr.string(
            doc = "The name of package being compiled, if not derived from `name`.",
        ),
        "rundir": attr.string(
            default = "",
            doc = dedent("""\
                A directory to cd to before the cargo_build_script is run. This should be a path relative to the exec root.

                The default behaviour (and the behaviour if rundir is set to the empty string) is to change to the relative path corresponding to the cargo manifest directory, which replicates the normal behaviour of cargo so it is easy to write compatible build scripts.

                If set to `.`, the cargo build script will run in the exec root.
            """),
        ),
        "rustc_flags": attr.string_list(
            doc = dedent("""\
                List of compiler flags passed to `rustc`.

                These strings are subject to Make variable expansion for predefined
                source/output path variables like `$location`, `$execpath`, and
                `$rootpath`. This expansion is useful if you wish to pass a generated
                file of arguments to rustc: `@$(location //package:target)`.
            """),
        ),
        "script": attr.label(
            doc = "The binary script to run, generally a `rust_binary` target.",
            executable = True,
            mandatory = True,
            cfg = "target",
            providers = [CargoBuildScriptRunfilesInfo],
        ),
        "tools": attr.label_list(
            doc = "Tools required by the build script.",
            allow_files = True,
            cfg = "exec",
        ),
        "version": attr.string(
            doc = "The semantic version (semver) of the crate",
        ),
        "_cargo_build_script_runner": attr.label(
            executable = True,
            allow_files = True,
            default = Label("//cargo/cargo_build_script_runner:cargo_build_script_runner"),
            cfg = "exec",
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
        "_experimental_symlink_execroot": attr.label(
            default = Label("//cargo/settings:experimental_symlink_execroot"),
        ),
    },
    fragments = ["cpp"],
    toolchains = [
        str(Label("//rust:toolchain_type")),
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
)

def _merge_env_dict(prefix_dict, suffix_dict):
    """Merges suffix_dict into prefix_dict, appending rather than replacing certain env vars."""
    for key in ["CFLAGS", "CXXFLAGS", "LDFLAGS"]:
        if key in prefix_dict and key in suffix_dict and prefix_dict[key]:
            prefix_dict[key] += " " + suffix_dict.pop(key)
    prefix_dict.update(suffix_dict)

def name_to_pkg_name(name):
    """Sanitize the name of cargo_build_script targets.

    Args:
        name (str): The name value pass to the `cargo_build_script` wrapper.

    Returns:
        str: A cleaned up name for a build script target.
    """
    if name.endswith("_bs"):
        return name[:-len("_bs")]
    return name
