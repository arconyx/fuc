{
  stdenv,
  lib,
  gleam,
  beamMinimalPackages,
  makeWrapper,
  pkgsBuildHost,
  coreutils,
  fd,
  git,
  cacert,
  toml-sort,
}:
let
  beamHost = pkgsBuildHost.beamMinimalPackages;
  project = lib.importTOML ./gleam.toml;

  mkGleamDeps =
    name: src: hash:
    stdenv.mkDerivation {
      name = "${name}-gleam-deps";

      nativeBuildInputs = [
        gleam
        git
        cacert
        toml-sort
        fd
      ];

      src = src;

      dontPatchShebangs = true;

      buildPhase = ''
        runHook preBuild

        # gleam deps download fails if it can't write to $HOME/.cache
        mkdir fake_home
        HOME=fake_home

        gleam deps download

        # packages.toml is randomly ordered with a header row
        toml-sort --all --no-comments --in-place build/packages/packages.toml

        rm build/packages/gleam.lock
        # .git dir is full of non-determinism and also forbidden store paths
        fd '^.git$' build/packages/ --exact-depth 2 --type directory --hidden --absolute-path --exec-batch rm  --recursive --verbose

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir $out
        cp -r build/packages/** $out

        runHook postInstall
      '';

      outputHashMode = "recursive";
      outputHashAlgo = if hash == "" then "sha256" else null;
      outputHash = hash;
    };
in
stdenv.mkDerivation (finalAttrs: {
  pname = project.name;
  version = project.version;

  src = builtins.path {
    path = ./.;
    name = project.name;
  };

  gleamDeps =
    mkGleamDeps "${finalAttrs.pname}-${finalAttrs.version}" finalAttrs.src
      finalAttrs.gleamDepsHash;
  gleamDepsHash = "sha256-fd0sqh7ya6PTP9npAm/Degcbgq0u1Tww+yJt1mNZ5Eo=";

  strictDeps = true;
  __structuredAttrs = true;

  nativeBuildInputs = [
    gleam

    beamHost.erlang
    (beamHost.rebar3WithPlugins {
      plugins = [ beamHost.pc ];
    })

    fd
    makeWrapper
  ];

  buildInputs = [
    beamMinimalPackages.erlang
    # erlang shipment invokes dirname
    coreutils
  ];

  buildPhase = ''
    runHook preBuild

    mkdir -p build/packages
    # gleam expects to be able to write to build/packages so we copy and chmod
    cp -r ${finalAttrs.gleamDeps}/** build/packages
    chmod -R u+w build/packages

    REBAR_CACHE_DIR="$TMP/rebar-cache"

    # The port compiler (pc) plugin for rebar3 needs some special environment variables
    # We use `fd` here because the library is versioned so the folder is named something like `erl_interface-5.7/lib/`
    # If no results are found then we we will be setting it to /lib, which should not exist.
    # Paths have a trailing slash so we don't need to include one when appending.
    TMP_ERL_INTERFACE_DIR="$(fd '^erl_interface-' ${beamMinimalPackages.erlang}/lib/erlang/lib --type directory --absolute-path --max-results 1 --exact-depth 1)"
    TMP_ERTS_DIR="$(fd '^erts-' ${beamMinimalPackages.erlang}/lib/erlang --type directory --absolute-path --max-results 1 --exact-depth 1)"
    # Yes, export is required for rebar to pick them up
    export ERL_EI_LIBDIR="$TMP_ERL_INTERFACE_DIRlib"
    # Joining the strings like this makes the end of the env vars clear
    # Using $($ENV_VAR) tries to evalutate $ENV_VAR
    # Using curly brackets reads as Nix substitution
    export ERL_CFLAGS="-I $TMP_ERL_INTERFACE_DIR""include -I $TMP_ERTS_DIR""include"

    gleam export erlang-shipment

    runHook postBuild
  '';

  # This recompiles the entire thing to run the tests, making it *slow*
  # Still, some tests beats no tests
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    gleam test
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/{bin,gleam}
    cp -r build/erlang-shipment $out/gleam/${project.name}
    makeWrapper $out/gleam/${project.name}/entrypoint.sh $out/bin/${project.name} \
    --add-flags run \
    --prefix PATH : ${
      lib.makeBinPath [
        beamMinimalPackages.erlang
        coreutils
      ]
    }

    runHook postInstall
  '';

  outputChecks.out = {
    disallowedRequisites = lib.optional (stdenv.buildPlatform != stdenv.hostPlatform) beamHost.erlang;
  };

})
