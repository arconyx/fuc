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
        awk 'NR == 1; NR > 1 {print $0 | "sort -n"}' build/packages/packages.toml > packages_sorted.toml
        cp packages_sorted.toml build/packages/packages.toml

        rm build/packages/gleam.lock
        # git dirs apparently break the fod
        rm -r build/packages/daemonic/.git

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
  gleamDepsHash = "sha256-7BzJaZ+B0v7EpPJB6NcGM7m08qq766czLVxqsPQAuSc=";

  strictDeps = true;

  nativeBuildInputs = [
    gleam
    beamHost.erlang
    makeWrapper
    (beamHost.rebar3WithPlugins {
      plugins = [ beamHost.pc ];
    })
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
    export ERL_EI_LIBDIR="$(${lib.getExe fd} erl_interface ${beamMinimalPackages.erlang}/lib/erlang/lib --type directory --absolute-path --max-results 1)/lib"

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
