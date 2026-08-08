{
  stdenv,
  lib,
  gleam,
  beamMinimalPackages,
  makeWrapper,
  pkgsBuildHost,
}:
let
  beamHost = pkgsBuildHost.beamMinimalPackages;

  project = lib.importTOML ./gleam.toml;
  manifest = lib.importTOML ./manifest.toml;

  depToHex =
    a:
    beamHost.fetchHex {
      pkg = a.name;
      version = a.version;
      sha256 = a.outer_checksum;
    };

  pkgs-toml = ''
    [packages]
    ${lib.concatLines (map (p: ''${p.name} = "${p.version}"'') manifest.packages)}
  '';

  erlang = beamMinimalPackages.erlang;
in
stdenv.mkDerivation {
  pname = project.name;
  version = project.version;

  src = builtins.path {
    path = ./.;
    name = project.name;
  };

  nativeBuildInputs = [
    gleam
    erlang
    makeWrapper
    (beamHost.rebar3WithPlugins {
      plugins = with beamHost; [ pc ];
    })
  ];

  # We don't strictly need this here but it is semantically correct
  # to include it
  buildInputs = [
    erlang
  ];

  configurePhase = ''
    runHook preConfigure

    mkdir -p build/packages

    cat <<EOF > build/packages/packages.toml
  ''
  + pkgs-toml
  + ''
    EOF
  ''
  + lib.concatLines (
    map (
      a: "cp -r --no-preserve=mode --dereference ${depToHex a} build/packages/${a.name}"
    ) manifest.packages
  )
  + ''

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export REBAR_CACHE_DIR="$TMP/rebar-cache"
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
    --prefix PATH : ${erlang}/bin

    runHook postInstall
  '';

}
