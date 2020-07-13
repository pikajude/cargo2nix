{
  cargo,
  rustc,

  lib,
  pkgs,
  buildPackages,
  rustLib,
  stdenv,
  buildEnv,
}:
{
  release, # Compiling in release mode?
  name,
  version,
  registry,
  src,
  features ? [ ],
  dependencies ? { },
  devDependencies ? { },
  buildDependencies ? { },
  profile,
  meta ? { },
  extraFlags ? [ ],
  extraRustcFlags ? [ ],
  extraRustcBuildFlags ? [ ],
  NIX_DEBUG ? 0,
  doCheck ? false,
  doBench ? false,
  doDoc ? false,
  extraCargoArguments ? [ ],
}:
with builtins; with lib;
let
  inherit (rustLib) realHostTriple decideProfile;

  wrapper = exename: pkgs.runCommand "${exename}-wrapper" {
    inherit (stdenv) shell;
    inherit exename rustc;
    utils = ./utils.sh;
  } ''
    mkdir -p $out/bin
    substituteAll ${./wrapper.sh} $out/bin/$exename
    chmod +x $out/bin/$exename
  '';

  ccForBuild="${buildPackages.stdenv.cc}/bin/${buildPackages.stdenv.cc.targetPrefix}cc";
  cxxForBuild="${buildPackages.stdenv.cc}/bin/${buildPackages.stdenv.cc.targetPrefix}c++";
  targetPrefix = stdenv.cc.targetPrefix;
  cc = stdenv.cc;
  ccForHost="${cc}/bin/${targetPrefix}cc";
  cxxForHost="${cc}/bin/${targetPrefix}c++";
  host-triple = realHostTriple stdenv.hostPlatform;
  depMapToList = deps:
    flatten
      (sort (a: b: elemAt a 0 < elemAt b 0)
        (mapAttrsToList (name: value: [ name "${value}" ]) deps));
  releaseArg = lib.optionalString release "--release";
  hasDefaultFeature = elem "default" features;
  featuresWithoutDefault = if hasDefaultFeature
    then filter (feature: feature != "default") features
    else features;
  commonCargoArgs =
    let
      featuresArg = if featuresWithoutDefault == [ ]
        then []
        else [ "--features" (concatStringsSep "," featuresWithoutDefault) ];
    in lib.concatLists [
      [ "--target" host-triple ]
      featuresArg
      (lib.optional (!hasDefaultFeature) "--no-default-features")
      extraCargoArguments
    ];

    runInEnv = cmd: ''
      (
        set -euo pipefail
        if (( NIX_DEBUG >= 1 )); then
          set -x
        fi
        env \
          "CC_${stdenv.buildPlatform.config}"="${ccForBuild}" \
          "CXX_${stdenv.buildPlatform.config}"="${cxxForBuild}" \
          "CC_${host-triple}"="${ccForHost}" \
          "CXX_${host-triple}"="${cxxForHost}" \
          "''${depKeys[@]}" \
          ${cmd}
      )
    '';

    inherit
      (({ right, wrong }: { runtimeDependencies = right; buildtimeDependencies = wrong; })
        (partition (drv: drv.stdenv.hostPlatform == stdenv.hostPlatform)
          (concatLists [
            (attrValues dependencies)
            (optionals doCheck (attrValues devDependencies))
            (attrValues buildDependencies)
          ])))
      runtimeDependencies buildtimeDependencies;

  namePrefix = lib.concatStringsSep "-" (lib.flatten [
    (lib.optional doBench "bench")
    (lib.optional doCheck "test")
    (lib.optional doDoc "doc")
    [ "crate" ]
  ]);

  drvAttrs = {
    inherit NIX_DEBUG;
    name = "${namePrefix}-${name}-${version}";
    inherit src version meta;
    propagatedBuildInputs = lib.unique
      (lib.concatMap (drv: drv.propagatedBuildInputs) runtimeDependencies);
    nativeBuildInputs = [ cargo buildPackages.pkg-config ];

    depsBuildBuild = with buildPackages; [ stdenv.cc jq remarshal ];

    # Running the default `strip -S` command on Darwin corrupts the
    # .rlib files in "lib/".
    #
    # See https://github.com/NixOS/nixpkgs/pull/34227
    stripDebugList = if stdenv.isDarwin then [ "bin" ] else null;

    passthru = {
      inherit
        name
        version
        registry
        dependencies
        devDependencies
        buildDependencies
        features;
      shell = pkgs.mkShell (removeAttrs drvAttrs ["src"]);
    };

    dependencies = depMapToList dependencies;
    buildDependencies = depMapToList buildDependencies;
    devDependencies = depMapToList (optionalAttrs doCheck devDependencies);

    inherit extraFlags extraRustcFlags extraRustcBuildFlags;

    # HACK: 2019-08-01: wasm32-wasi always uses `wasm-ld`
    configureCargo = ''
      mkdir -p .cargo
      cat > .cargo/config <<'EOF'
      [target."${realHostTriple stdenv.buildPlatform}"]
      linker = "${ccForBuild}"
    '' + optionalString (stdenv.buildPlatform != stdenv.hostPlatform && !(stdenv.hostPlatform.isWasi or false)) ''
      [target."${host-triple}"]
      linker = "${ccForHost}"
    '' + ''
      EOF
    '';

    manifestPatch = toJSON {
      features = genAttrs features (_: [ ]);
      profile.${ decideProfile doCheck release } = profile;
    };

    overrideCargoManifest = ''
      echo [[package]] > Cargo.lock
      echo name = \"${name}\" >> Cargo.lock
      echo version = \"${version}\" >> Cargo.lock
      echo source = \"registry+${registry}\" >> Cargo.lock
      mv Cargo.toml Cargo.original.toml
      remarshal -if toml -of json Cargo.original.toml \
        | jq "{ package, lib, bin, test, example
              , bench: (if \"$registry\" == \"unknown\" then .bench else null end)
         } + $manifestPatch" \
        | remarshal -if json -of toml > Cargo.toml
    '';

    configurePhase =
      ''
        runHook preConfigure
        runHook configureCargo
        runHook postConfigure
      '';

    inherit commonCargoArgs;

    # Unfortunately we can't share any build artifacts between the build and other
    # phases because `cargo test` uses a different config (resulting in different metadata).
    # So we don't pass `--release` to any other subcommands even though most of them accept it.
    runCargo = runInEnv "cargo build $CARGO_VERBOSE $CARGO_RELEASE $commonCargoArgs";

    checkPhase = runInEnv ''
      cargo test $CARGO_VERBOSE $commonCargoArgs --target-dir target_check
    '';

    runBenchmarks = ''
      if [ -n "$doBench" ]; then
        ${runInEnv ''cargo bench $CARGO_VERBOSE $commonCargoArgs --target-dir target_check''}
      fi
    '';

    runRustdoc = ''
      if [ -n "$doDoc" ]; then
        docDir="target_check/${host-triple}/doc"
        mkdir -p "$docDir"
        linkDocs "$docDir" $dependencies $devDependencies
        ${runInEnv ''
          NIX_RUSTC_FLAGS="$(makeExternDocFlags $dependencies $devDependencies) -L dependency=$(realpath deps)" \
          cargo doc $CARGO_VERBOSE $commonCargoArgs --target-dir target_check
        ''}
        mkdir -p $out/share
        cp -rT "$docDir" $out/share/doc
      fi
    '';

    # set doCheck here so that we can conditionally apply overrides when
    # a crate is being tested or not. HOWEVER this does nothing for cross
    # builds, see below
    inherit doCheck doBench doDoc;
    # manually override doCheck. stdenv.mkDerivation sets it to false if
    # hostPlatform != buildPlatform, but that's not necessarily correct (for example,
    # when targeting musl from gnu linux)
    setBuildEnv = ''
      export doCheck=${if doCheck then "1" else ""}
      isProcMacro="$( \
        remarshal -if toml -of json Cargo.original.toml \
        | jq -r 'if .lib."proc-macro" or .lib."proc_macro" then "1" else "" end' \
      )"
      crateName="$(
        remarshal -if toml -of json Cargo.original.toml \
        | jq -r 'if .lib."name" then .lib."name" else "${replaceChars ["-"] ["_"] name}" end' \
      )"
      . ${./utils.sh}
      export CARGO_VERBOSE=`cargoVerbosityLevel $NIX_DEBUG`
      export NIX_RUST_METADATA=`extractHash $out`
      export CARGO_HOME=`pwd`/.cargo
      mkdir -p deps build_deps
      linkFlags=(`makeExternCrateFlags $dependencies $devDependencies`)
      buildLinkFlags=(`makeExternCrateFlags $buildDependencies`)
      linkExternCrateToDeps `realpath deps` $dependencies $devDependencies
      linkExternCrateToDeps `realpath build_deps` $buildDependencies

      export NIX_RUSTC_FLAGS="''${linkFlags[@]} -L dependency=$(realpath deps)"
      export NIX_RUSTC_BUILD_FLAGS="''${buildLinkFlags[@]} -L dependency=$(realpath build_deps)"
      export NIX_EXTRA_RUST_FLAGS="$extraFlags"
      export NIX_EXTRA_RUSTC_FLAGS="$extraRustcFlags"
      export NIX_EXTRA_RUSTC_BUILD_FLAGS="$extraRustcBuildFlags"
      export RUSTC=${wrapper "rustc"}/bin/rustc
      export RUSTDOC=${wrapper "rustdoc"}/bin/rustdoc
      export CARGO_RELEASE=${releaseArg}

      depKeys=(`loadDepKeys $dependencies`)

      if (( NIX_DEBUG >= 1 )); then
        echo $NIX_RUST_LINK_FLAGS
        echo $NIX_RUST_BUILD_LINK_FLAGS
        for key in ''${depKeys[@]}; do
          echo $key
        done
      fi
    '';

    buildPhase = ''
      runHook preBuild
      runHook overrideCargoManifest
      runHook setBuildEnv
      runHook runCargo
      runHook runBenchmarks
      runHook runRustdoc
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib
      cargo_links="$(remarshal -if toml -of json Cargo.original.toml | jq -r '.package.links | select(. != null)')"
      install_crate ${host-triple} ${if release then "release" else "debug"}
      runHook postInstall
    '';
  } // buildEnv;
in
  stdenv.mkDerivation drvAttrs
