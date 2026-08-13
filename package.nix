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

  nativeBuildInputs = [
    gleam
    beamHost.erlang
    makeWrapper
    (beamHost.rebar3WithPlugins {
      plugins = [ beamHost.pc ];
    })
    fd
  ];

  # We don't strictly need this here but it is semantically correct
  # to include it
  buildInputs = [
    beamMinimalPackages.erlang
  ];

  buildPhase = ''
    runHook preBuild

    mkdir -p build/packages
    # gleam expects to be able to write to build/packages so we copy and chmod
    cp -r ${finalAttrs.gleamDeps}/** build/packages
    chmod -R u+w build/packages

    export REBAR_CACHE_DIR="$TMP/rebar-cache"
    # We use `fd` here because the library is versioned so the folder is namedsomething like `erl_interface-5.7/lib/`
    # If no results are found then we we will be setting it to /lib, which should not exist.
    export ERL_EI_LIBDIR="$(fd erl_interface ${beamMinimalPackages.erlang}/lib/erlang/lib --type directory --absolute-path --max-results 1)/lib"

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

})
