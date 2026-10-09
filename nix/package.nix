{ lib, stdenvNoCC, fetchurl, unzip
# Set to the latest published release (the GitHub asset and its SHA256SUMS entry).
, version ? "0.1.0"
, url ? "https://github.com/alexjmiller5/media-center/releases/download/v${version}/MediaCenter-v${version}.zip"
, hash ? "sha256-04Rqmhi3QpfOUm+lBWa016l531w5AW028t+tHJ/ulY8="
}:
stdenvNoCC.mkDerivation {
  pname = "media-center";
  inherit version;
  src = fetchurl { inherit url hash; };
  nativeBuildInputs = [ unzip ];
  phases = [ "unpackPhase" "installPhase" ];
  unpackPhase = ''unzip -q "$src"'';
  # The release is signed, notarized and stapled; any fixup would break its seal.
  dontFixup = true;
  dontStrip = true;
  installPhase = ''
    mkdir -p "$out/Applications"
    cp -R MediaCenter.app "$out/Applications/"
  '';
  meta = {
    description = "Native feed of saved and newly released articles, videos and TV from a Soma service";
    homepage = "https://github.com/alexjmiller5/media-center";
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
