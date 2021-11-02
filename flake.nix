{
  description = "Solana CLI";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    solana-src = {
	    url = "github:solana-labs/solana?tag=v1.8.2";
    	flake = false;
    };
		fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, solana-src, fenix }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # https://github.com/solana-labs/solana/blob/master/scripts/cargo-install-all.sh#L71
        endUserBins = [
          "cargo-build-bpf"
          "cargo-test-bpf"
          "solana"
          "solana-install"
          "solana-install-init"
          "solana-keygen"
          "solana-faucet"
          "solana-stake-accounts"
          "solana-tokens"
          "solana-test-validator"
        ];

        meta = with pkgs.stdenv; with pkgs.lib; {
          homepage = "https://solana.com/";
          description = "Solana is a decentralized blockchain built to enable scalable, user-friendly apps for the world.";
          platforms = platforms.unix ++ platforms.darwin;
        };

        llvmPkgs = pkgs.llvmPackages_12;
        clangPkg = pkgs.clang_12;

        # Here's an unfinished attempt at adding solana to Nixpkgs where the
        # person had to remove some tests and comment some out.
        # https://github.com/NixOS/nixpkgs/pull/121009/files
        solana = (pkgs.makeRustPlatform {
          inherit (fenix.packages.${system}.stable) cargo rustc;
        }).buildRustPackage {
            pname = "solana";
            version = "1.8.2";
            src = solana-src;
            cargoSha256 = "sha256-YVZ3MVbMWn2lKlH9qtIGyK+pxlVDRvc35SXEFPXM79M=";#pkgs.lib.fakeSha256;

            doCheck = false;

            nativeBuildInputs = with pkgs; [
              rustfmt
              llvmPkgs.llvm
              clangPkg
              protobuf
              pkg-config
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
            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            LLVM_CONFIG_PATH = "${pkgs.llvm}/bin/llvm-config";

            cargoBuildFlags = builtins.map (binName: "--bin=${binName}") endUserBins;

            postInstall = ''
            	mkdir -p $out/bin/sdk
            	cp -r ${solana-src}/sdk/bpf $out/bin/sdk/
            '';
          };

      in
      rec {
        packages = flake-utils.lib.flattenTree {
          inherit solana;
        };
        defaultPackage = packages.solana;
        apps.solana = flake-utils.lib.mkApp { drv = packages.solana; };
        defaultApp = apps.solana;
      }
    );
}
