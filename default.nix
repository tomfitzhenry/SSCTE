# Builds the SSCTE serial-tcp-bridge firmware for ESP32-S3.
#
# Usage:
#   nix-build      # builds the firmware for esp32s3
#
# Outputs in result/:
#   bootloader.bin
#   partition-table.bin
#   serial_tcp_bridge.bin    app image
#   merged-firmware.bin      single image; flash with:
#                            esptool.py write-flash 0x0 merged-firmware.bin
#   flash                    helper that flashes the board over serial
#   build/                   full ESP-IDF build tree (sdkconfig, flasher_args.json, ...)
let
  # Same nixpkgs revision the esp-dev-packages flake pins (nixos-25.11 branch).
  nixpkgsRev = "d351d0653aeb7877273920cd3e823994e7579b0b";
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsRev}.tar.gz";
    sha256 = "049hhh8vny7nyd26dfv7i962jpg18xb5bg6cv126b8akw5grb0dg";
  };

  # Community overlay providing ESP-IDF (v5.5.2) and the Xtensa/RISC-V
  # toolchains. https://github.com/mirrexagon/nixpkgs-esp-dev
  espDevRev = "5287d6e1ca9e15ebd5113c41b9590c468e1e001b";
  espDev = builtins.fetchTarball {
    url = "https://github.com/mirrexagon/nixpkgs-esp-dev/archive/${espDevRev}.tar.gz";
    sha256 = "12mhbc5r5k5ng2361184blfgn58hiqpla7mjrk6ppy0xjsnpaqa1";
  };

  pkgs = import nixpkgs {
    overlays = [ (import "${espDev}/overlay.nix") ];

    # esptool needs ecdsa, which is marked insecure
    # (https://github.com/mirrexagon/nixpkgs-esp-dev/issues/109).
    config.permittedInsecurePackages = [
      "python3.13-ecdsa-0.19.1"
    ];
  };

  target = "esp32s3";
  idf = pkgs.esp-idf-xtensa;
  projectSrc = ./.;

  flash = pkgs.writeShellApplication {
    name = "flash";

    # The vars below are assigned via `eval` from flasher_args.json, which
    # shellcheck cannot see.
    checkPhase = "";
    text = ''
      set -e
      SCRIPT_DIR="$(dirname "$(readlink -f "''${BASH_SOURCE[0]}")")"
      cd "$SCRIPT_DIR/build"

      eval "$(
        jq -r '.extra_esptool_args | to_entries | map("\(.key)=\(.value|@sh)") | .[]' "flasher_args.json"
      )"

      stubarg=""
      if [ "$stub" = "false" ]; then
        stubarg="--no-stub"
      fi

      ${idf}/python-env/bin/python3 -m esptool "$@" --chip "$chip" --before "$before" --after "$after" $stubarg write_flash "@flash_args"
    '';
    runtimeInputs = [ idf pkgs.jq ];
  };
in
pkgs.stdenv.mkDerivation {
  pname = "serial-tcp-bridge";
  version = target;

  src = projectSrc;

  buildInputs = [ idf ];

  phases = [ "buildPhase" ];

  buildPhase = ''
    cp -r ${projectSrc}/* .
    chmod -R +w .

    # idf.py wants a cache directory somewhere under $HOME.
    mkdir temp-home
    export HOME=$(readlink -f temp-home)

    # Keep the build offline; this project has no component-manager deps.
    export IDF_COMPONENT_MANAGER=0

    idf.py --preview set-target ${target}
    idf.py build

    # Single-file image for easy flashing (contents match build/flash_args).
    (cd build && ${idf}/python-env/bin/python3 -m esptool --chip ${target} merge_bin -o ../merged-firmware.bin @flash_args)

    mkdir -p $out
    cp -r build $out/build
    cp sdkconfig $out/build/sdkconfig
    cp build/bootloader/bootloader.bin $out/bootloader.bin
    cp build/partition_table/partition-table.bin $out/partition-table.bin
    cp build/serial_tcp_bridge.bin merged-firmware.bin $out/
    if [ -f build/spiffs.bin ]; then
        cp build/spiffs.bin $out/
    fi
    cp ${pkgs.lib.getExe flash} $out/flash
  '';

  meta = {
    description = "SSCTE serial TCP bridge firmware (no TLS)";
    platforms = pkgs.lib.platforms.all;
  };
}
