{
  description = "termux-widget (retargeted to nix-on-droid / com.termux.nix) Android build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            # Required to accept the Android SDK licenses non-interactively.
            android_sdk.accept_license = true;
          };
        };

        # SDK versions must match app/build.gradle + gradle.properties:
        #   compileSdkVersion = 35, targetSdkVersion = 28, minSdkVersion = 24
        #   AGP 8.7.3 defaults to build-tools 34.0.0; we pin 35.0.0 in
        #   app/build.gradle but ship 34.0.0 too so AGP is satisfied either way.
        buildToolsVersion = "35.0.0";
        platformVersions = [ "35" "28" ];

        androidComposition = pkgs.androidenv.composeAndroidPackages {
          platformToolsVersion = "35.0.2";
          buildToolsVersions = [ buildToolsVersion "34.0.0" ];
          platformVersions = platformVersions;
          includeEmulator = false;
          includeSystemImages = false;
          includeSources = false;
          includeNDK = false;
          # cmdline-tools needed so AGP can resolve the SDK layout.
          cmdLineToolsVersion = "13.0";
        };

        androidSdk = androidComposition.androidsdk;
        androidSdkRoot = "${androidSdk}/libexec/android-sdk";

        # AGP 8.7 requires JDK 17 to run Gradle. Bytecode target stays Java 11
        # (compileOptions in app/build.gradle), so JDK 17 toolchain is correct.
        jdk = pkgs.jdk17;
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            jdk
            pkgs.gradle_8
            androidSdk
          ];

          ANDROID_HOME = androidSdkRoot;
          ANDROID_SDK_ROOT = androidSdkRoot;
          # jdk.home resolves to the platform-correct JDK root (on darwin the
          # zulu JDK lives under .../Contents/Home, not .../lib/openjdk).
          JAVA_HOME = jdk.home;

          # AGP needs an explicit aapt2 from the matching build-tools.
          GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdkRoot}/build-tools/${buildToolsVersion}/aapt2";

          shellHook = ''
            # Write local.properties so `./gradlew` (invoked directly) also finds the SDK.
            echo "sdk.dir=${androidSdkRoot}" > local.properties
            echo ""
            echo "Android build environment ready."
            echo "  ANDROID_HOME = $ANDROID_HOME"
            echo "  JAVA_HOME    = $JAVA_HOME"
            echo ""
            echo "Build with:  ./gradlew :app:assembleDebug"
            echo "APK output:  app/build/outputs/apk/debug/"
          '';
        };

        # Reproducible package build: nix build .#apk
        packages = {
          apk = pkgs.stdenv.mkDerivation {
            pname = "termux-widget-nix";
            version = "0.15.0";
            src = self;

            nativeBuildInputs = [ jdk pkgs.gradle_8 androidSdk ];

            ANDROID_HOME = androidSdkRoot;
            ANDROID_SDK_ROOT = androidSdkRoot;
            JAVA_HOME = jdk.home;

            buildPhase = ''
              export GRADLE_USER_HOME=$(mktemp -d)
              echo "sdk.dir=${androidSdkRoot}" > local.properties
              gradle --offline --no-daemon \
                -Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdkRoot}/build-tools/${buildToolsVersion}/aapt2 \
                :app:assembleDebug
            '';

            installPhase = ''
              mkdir -p $out
              cp app/build/outputs/apk/debug/*.apk $out/
            '';

            # Network is needed to fetch Gradle deps; this package build is
            # therefore not fully hermetic. Prefer `nix develop` + gradlew for
            # day-to-day builds. Kept for convenience.
            __noChroot = true;
          };

          default = self.packages.${system}.apk;
        };
      });
}
