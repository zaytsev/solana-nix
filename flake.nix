{
  description = "Solana";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    solanaSrc = {
      url = "github:solana-labs/solana/v1.9.1";
      flake = false;
    };
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, solanaSrc, fenix }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        stdenv = pkgs.stdenv;
        solanaVersion = "1.9.1";

        meta = with pkgs.stdenv; with pkgs.lib; {
          homepage = "https://solana.com/";
          description = "Solana is a decentralized blockchain built to enable scalable, user-friendly apps for the world.";
          platforms = platforms.unix ++ platforms.darwin;
        };

        llvmPkgs = pkgs.llvmPackages_12;
        clangPkg = pkgs.clang_12;

        solanaBuild = { pname, version, buildTargets, cargoSha256, patches ? [ ], postInstall ? [ ] }: (pkgs.makeRustPlatform {
          inherit (fenix.packages.${system}.stable) cargo rustc;
        }).buildRustPackage {
          inherit pname version cargoSha256 patches postInstall;
          src = solanaSrc;
          #cargoSha256 = pkgs.lib.fakeSha256;

          doCheck = false;

          nativeBuildInputs = with pkgs; [
            rustfmt
            llvmPkgs.llvm
            clangPkg
            protobuf
            pkg-config
            perl
          ];

          buildInputs = with pkgs; [
            hidapi
            rustfmt
            llvmPkgs.libclang
            openssl
            zlib
          ] ++ (with pkgs.darwin.apple_sdk.frameworks; pkgs.lib.optionals pkgs.stdenv.isDarwin [
            System
            IOKit
            Security
            CoreFoundation
            AppKit
          ]) ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.udev ]);

          # https://hoverbear.org/blog/rust-bindgen-in-nix/
          preBuild = with pkgs; ''
            # From: https://github.com/NixOS/nixpkgs/blob/1fab95f5190d087e66a3502481e34e15d62090aa/pkgs/applications/networking/browsers/firefox/common.nix#L247-L253
            # Set C flags for Rust's bindgen program. Unlike ordinary C
            # compilation, bindgen does not invoke $CC directly. Instead it
            # uses LLVM's libclang. To make sure all necessary flags are
            # included we need to look in a few places.
            export BINDGEN_EXTRA_CLANG_ARGS="$(< ${stdenv.cc}/nix-support/libc-crt1-cflags) \
              $(< ${stdenv.cc}/nix-support/libc-cflags) \
              $(< ${stdenv.cc}/nix-support/cc-cflags) \
              $(< ${stdenv.cc}/nix-support/libcxx-cxxflags) \
              ${lib.optionalString stdenv.cc.isClang "-idirafter ${stdenv.cc.cc}/lib/clang/${lib.getVersion stdenv.cc.cc}/include"} \
              ${lib.optionalString stdenv.cc.isGNU "-isystem ${stdenv.cc.cc}/include/c++/${lib.getVersion stdenv.cc.cc} -isystem ${stdenv.cc.cc}/include/c++/${lib.getVersion stdenv.cc.cc}/${stdenv.hostPlatform.config} -idirafter ${stdenv.cc.cc}/lib/gcc/${stdenv.hostPlatform.config}/${lib.getVersion stdenv.cc.cc}/include"} \
            "
          '';
          LIBCLANG_PATH = "${llvmPkgs.libclang.lib}/lib";
          LLVM_CONFIG_PATH = "${pkgs.llvm}/bin/llvm-config";

          cargoBuildFlags = builtins.map (binName: "--bin=${binName}") buildTargets;
        };

        cli = solanaBuild {
          pname = "solana-cli";
          version = solanaVersion;
          buildTargets = [ "solana" "solana-keygen" ];
          cargoSha256 = "sha256-yHaNMwDPvGfcDSVn8/yuTyyobNG7wys/MCSwJ7XGsj4=";
          #cargoSha256 = pkgs.lib.fakeSha256;
        };

        devTools = solanaBuild {
          pname = "solana-dev-tools";
          version = solanaVersion;
          buildTargets = [ "cargo-build-bpf" "cargo-test-bpf" "solana-test-validator" ];
          patches = [ ./patches/cargo-build-bpf-tools.patch ./patches/bpf-scripts-env.patch ];
          cargoSha256 = "sha256-WQ+jv7y6627HuwLp4y3A4J3BFKc6IBmvAussKSzmOBo=";
          #cargoSha256 = pkgs.lib.fakeSha256;
          postInstall = ''
            	mkdir -p $out/bpf/dependencies/
              cp -r ${solanaSrc}/sdk/bpf $out/
              mkdir -p $out/bin/sdk
              ln -s $out/bpf $out/bin/sdk/bpf
          '';
        };

        bpfTools = stdenv.mkDerivation {
          pname = "solana-bpf-tools";
          version = "1.21";
          src = builtins.fetchurl {
            url = "https://github.com/solana-labs/bpf-tools/releases/download/v1.21/solana-bpf-tools-linux.tar.bz2";
            sha256 = "sha256:0cwkda0j7jyzga7bls60m5fzc515jxvd0icaijc3g76x3dy50k3w";
          };

          nativeBuildInputs = with pkgs; [ gnutar ];

          buildInputs = with pkgs; [
            zlib
            openssl
          ];

          dontUnpack = true;
          dontPatch = true;
          dontBuild = true;

          installPhase = ''
            mkdir -p $out
            tar -xf $src -C $out
          '';

          fixupPhase = ''
                if [ -d $out/rust/bin ]; then
                  for file in $(find $out/rust/bin -type f); do
                    if isELF "$file"; then
                      patchelf \
                        --set-interpreter ${stdenv.cc.bintools.dynamicLinker} \
                        --set-rpath "${pkgs.lib.makeLibraryPath [ stdenv.cc.cc pkgs.zlib pkgs.openssl ]}:$out/rust/lib" \
                        "$file" || true
                    fi
                  done
                fi
                if [ -d $out/rust/lib ]; then
                  for file in $(find $out/rust/lib -type f); do
                    if isELF "$file"; then
                      patchelf \
                        --set-rpath "${pkgs.lib.makeLibraryPath [ stdenv.cc.cc pkgs.zlib pkgs.openssl ]}:$out/rust/lib" \
                        "$file" || true
                    fi
                  done
                fi
                if [ -d $out/llvm/bin ]; then
                  for file in $(find $out/llvm/bin -type f); do
                    if isELF "$file"; then
                      patchelf \
                        --set-interpreter ${stdenv.cc.bintools.dynamicLinker} \
                        --set-rpath "${pkgs.lib.makeLibraryPath [ stdenv.cc.cc pkgs.zlib pkgs.openssl ]}:$out/llvm/lib" \
                        "$file" || true
                    fi
                  done
                fi
                if [ -d $out/llvm/lib ]; then
                  for file in $(find $out/rust/lib -type f); do
                    if isELF "$file"; then
                      patchelf \
                        --set-rpath "${pkgs.lib.makeLibraryPath [ stdenv.cc.cc pkgs.zlib pkgs.openssl ]}:$out/llvm/lib" \
                        "$file" || true
                    fi
                  done
                fi
            	'';
        };

				sdk = pkgs.symlinkJoin {
  				name = "solana-bpf-sdk-${solanaVersion}";
  				paths = [ devTools bpfTools ];
  				postBuild = ''
  					mkdir -p $out/bpf/dependencies/bpf-tools
  					ln -s $out/rust $out/bpf/dependencies/bpf-tools/rust
  					ln -s $out/llvm $out/bpf/dependencies/bpf-tools/llvm
  				'';
				};

      in
      rec {
        packages = flake-utils.lib.flattenTree {
          inherit cli sdk;
        };
        defaultPackage = cli;
        apps.solana = flake-utils.lib.mkApp { drv = cli; };
        defaultApp = apps.cli;
      }
    );
}
