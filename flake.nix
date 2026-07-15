{
  description = "Phoenix MapReduce benchmark binaries for native builds and x86_64 guest inputs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "riscv64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f (import nixpkgs { inherit system; }) system);
    in
    {
      packages = forAllSystems (pkgs: system:
        let
          lib = pkgs.lib;

          dataSources = {
            histogram = {
              url = "https://csl.stanford.edu/~christos/data/histogram.tar.gz";
              hash = "sha256-uAqfnPUKN/ZeOUM9KjCteyDkZXbATxMVvDbWzTs4rTY=";
            };
            linear-regression = {
              url = "https://csl.stanford.edu/~christos/data/linear_regression.tar.gz";
              hash = "sha256-TRk9eKujXSVOHZpMUnUHbV7GuikDhhX8x0H8pa5Hs3M=";
            };
            string-match = {
              url = "https://csl.stanford.edu/~christos/data/string_match.tar.gz";
              hash = "sha256-oDM2akSUCFho46T0nab522c85wg6YI12jedr3iU5ZD8=";
            };
            word-count = {
              url = "https://csl.stanford.edu/~christos/data/word_count.tar.gz";
              hash = "sha256-ZEfwzEc4qM/RrSoQiQrnHfFMvHCalUdUH6P9uTQrJHs=";
            };
          };
          mkPhoenixData = name: source:
            pkgs.runCommand "phoenix-input-data-${name}" {
              nativeBuildInputs = with pkgs; [ gnutar gzip ];
              passthru.source = source.url;
            } ''
              mkdir -p $out
              tar -xzf ${pkgs.fetchurl source} -C $out
            '';
          phoenixDataPackages = lib.mapAttrs mkPhoenixData dataSources;
          phoenixData = pkgs.symlinkJoin {
            name = "phoenix-input-data";
            paths = lib.attrValues phoenixDataPackages;
            passthru.sources = lib.mapAttrs (_: source: source.url) dataSources;
          };

          apps = [
            { benchmark = "histogram"; dir = "histogram"; args = [ "data/histogram_datafiles/small.bmp" ]; inputFiles = [ "data/histogram_datafiles/small.bmp" ]; }
            { benchmark = "kmeans"; dir = "kmeans"; args = [ "-d" "3" "-c" "3" "-p" "1000" "-s" "1000" ]; inputFiles = [ ]; }
            { benchmark = "linear_regression"; dir = "linear_regression"; args = [ "data/linear_regression_datafiles/key_file_50MB.txt" ]; inputFiles = [ "data/linear_regression_datafiles/key_file_50MB.txt" ]; }
            { benchmark = "matrix_multiply"; dir = "matrix_multiply"; args = [ "32" ]; inputFiles = [ ]; }
            { benchmark = "pca"; dir = "pca"; args = [ "-r" "64" "-c" "64" "-s" "100" ]; inputFiles = [ ]; }
            { benchmark = "string_match"; dir = "string_match"; args = [ "data/string_match_datafiles/key_file_50MB.txt" ]; inputFiles = [ "data/string_match_datafiles/key_file_50MB.txt" ]; }
            { benchmark = "word_count"; dir = "word_count"; args = [ "data/word_count_datafiles/word_10MB.txt" ]; inputFiles = [ "data/word_count_datafiles/word_10MB.txt" ]; }
          ];

          modeSuffix = mode: if mode == "mapreduce" then "" else "-${mode}";
          sourceName = app: mode: "${app.benchmark}${modeSuffix mode}";
          outputName = staticSuffix: app: mode: "${app.benchmark}${modeSuffix mode}-v2${staticSuffix}";
          aliasName = staticSuffix: app: mode: "${app.benchmark}${modeSuffix mode}${staticSuffix}";
          modeForPackage = mode:
            if mode == "seq" then [ "seq" ]
            else if mode == "pthread" then [ "pthread" ]
            else [ "mapreduce" "seq" "pthread" ];

          mkManifest = { manifestApps ? apps, modes, staticSuffix, optimization, targetTriple, libcName, isStatic, nonPie }:
            let
              entries = lib.concatMap (app:
                map (mode: {
                  benchmark = app.benchmark;
                  implementation = "phoenix-2.0";
                  version = "v2";
                  mode = mode;
                  binary = "bin/${outputName staticSuffix app mode}";
                  alias = "bin/${aliasName staticSuffix app mode}";
                  args = app.args;
                  input_files = app.inputFiles;
                  optimization = optimization;
                  target_triple = targetTriple;
                  libc = libcName;
                  static = isStatic;
                  non_pie = nonPie;
                }) modes) manifestApps;
            in pkgs.writeText "manifest.json" (builtins.toJSON {
              schema = 1;
              package_system = system;
              target_triple = targetTriple;
              optimization = optimization;
              benchmarks = entries;
              data_sources = {
                histogram = "https://csl.stanford.edu/~christos/data/histogram.tar.gz";
                linear_regression = "https://csl.stanford.edu/~christos/data/linear_regression.tar.gz";
                string_match = "https://csl.stanford.edu/~christos/data/string_match.tar.gz";
                word_count = "https://csl.stanford.edu/~christos/data/word_count.tar.gz";
              };
            });

          mkPhoenix =
            { stdenv
            , buildPkgs
            , name
            , modes
            , appsToBuild ? apps
            , staticMusl ? false
            , staticLink ? false
            , staticSuffix ? (if staticMusl then "-static-musl" else "")
            , optimization ? "-O2"
            , extraCFlags ? [ ]
            , extraPostPatch ? ""
            , hardeningDisable ? [ ]
            , disableFixup ? (staticMusl || staticLink)
            , nonPie ? (staticMusl || staticLink)
            , targetTriple ? stdenv.hostPlatform.config
            , libcName ? stdenv.hostPlatform.libc or "glibc"
            }:
            let
              selectedModes = modeForPackage modes;
              staticLinked = staticMusl || staticLink;
              linkerCCFlags = lib.optionals staticLinked [ "-static" "-no-pie" ];
              cflags = lib.concatStringsSep " " ([
                "-D_LINUX_"
                "-D__x86_64__"
                "-D_GNU_SOURCE"
                "-Wall"
                optimization
                "-g"
              ] ++ lib.optionals staticLinked [
                "-fno-PIE"
                "-mno-avx"
                "-mno-avx2"
                "-fno-tree-vectorize"
              ] ++ extraCFlags);
              ccBase = "${stdenv.cc.targetPrefix}gcc";
              cc = lib.concatStringsSep " " ([ ccBase ] ++ linkerCCFlags);
              ar = "${stdenv.cc.targetPrefix}ar";
              ranlib = "${stdenv.cc.targetPrefix}ranlib";
              manifest = mkManifest {
                inherit staticSuffix optimization targetTriple libcName nonPie;
                isStatic = staticLinked;
                manifestApps = appsToBuild;
                modes = selectedModes;
              };
              makeTargets = app: lib.concatStringsSep " " (map (mode: sourceName app mode) selectedModes);
              buildApps = lib.concatMapStringsSep "\n" (app: ''
                make -C phoenix-2.0/tests/${app.dir} ${makeTargets app} \
                  CC="${cc}" AR="${ar}" RANLIB="${ranlib}" CFLAGS="${cflags}"
              '') appsToBuild;
              installApps = lib.concatMapStringsSep "\n" (app:
                lib.concatMapStringsSep "\n" (mode: ''
                  install -m755 phoenix-2.0/tests/${app.dir}/${sourceName app mode} \
                    "$out/bin/${outputName staticSuffix app mode}"
                  cp -p "$out/bin/${outputName staticSuffix app mode}" \
                    "$out/bin/${aliasName staticSuffix app mode}"
                '') selectedModes) appsToBuild;
            in
            stdenv.mkDerivation {
              pname = name;
              version = "2.0";
              src = self;

              nativeBuildInputs = with buildPkgs; [ gnumake gnused coreutils ];
              dontConfigure = true;
              dontStrip = true;
              dontPatchELF = disableFixup;
              dontFixup = disableFixup;
              inherit hardeningDisable;

              postPatch = ''
                find phoenix-2.0 sample_apps -type f \( -name '*.c' -o -name '*.h' \) \
                  -exec sed -i 's@#include <sys/unistd.h>@#include <unistd.h>@' {} +
                substituteInPlace phoenix-2.0/tests/string_match/string_match-pthread.c \
                  --replace-fail '#include <crypt.h>' '/* crypt.h unused */'
                ${extraPostPatch}
              '';

              buildPhase = ''
                runHook preBuild
                make -C phoenix-2.0/src \
                  CC="${cc}" AR="${ar}" RANLIB="${ranlib}" CFLAGS="${cflags}"
                ${buildApps}
                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall
                mkdir -p "$out/bin"
                ${installApps}
                cp ${manifest} "$out/manifest.json"
                runHook postInstall
              '';

              meta = {
                description = "Phoenix 2 benchmark binaries (${modes}, ${targetTriple})";
                platforms = lib.platforms.linux;
              };
            };

          muslPkgs = pkgs.pkgsCross.musl64;
          glibcX86Pkgs = pkgs.pkgsCross.gnu64;
          mkNative = modes: mkPhoenix {
            stdenv = pkgs.stdenv;
            buildPkgs = pkgs;
            name = "phoenix-${modes}";
            inherit modes;
            staticMusl = false;
            optimization = "-O2";
            targetTriple = pkgs.stdenv.hostPlatform.config;
            libcName = "glibc";
          };
          mkMusl = modes: optName: optFlag: mkPhoenix {
            stdenv = muslPkgs.stdenv;
            buildPkgs = pkgs;
            name = "phoenix-x86_64-musl-static-${modes}${optName}";
            inherit modes;
            staticMusl = true;
            optimization = optFlag;
            targetTriple = "x86_64-linux-musl";
            libcName = "musl";
          };
          mkDynamicMusl = modes: mkPhoenix {
            stdenv = muslPkgs.stdenv;
            buildPkgs = pkgs;
            name = "phoenix-x86_64-musl-dynamic-${modes}";
            inherit modes;
            staticMusl = false;
            optimization = "-O2";
            extraCFlags = [ "-mno-avx" "-mno-avx2" "-fno-tree-vectorize" "-fno-stack-protector" "-fno-PIE" "-no-pie" ];
            hardeningDisable = [ "all" ];
            disableFixup = true;
            nonPie = true;
            targetTriple = "x86_64-linux-musl";
            libcName = "musl";
          };
          mkDynamicGlibc = modes: mkPhoenix {
            stdenv = glibcX86Pkgs.stdenv;
            buildPkgs = pkgs;
            name = "phoenix-x86_64-glibc-dynamic-${modes}";
            inherit modes;
            appsToBuild = lib.filter (app: lib.elem app.benchmark [ "histogram" "kmeans" "linear_regression" "matrix_multiply" "pca" "string_match" "word_count" ]) apps;
            optimization = "-O2";
            extraCFlags = [ "-mno-avx" "-mno-avx2" "-fno-tree-vectorize" "-fno-stack-protector" "-fno-PIE" "-no-pie" ]
              ++ lib.optionals (modes != "seq") [ "-pthread" ];
            extraPostPatch = lib.optionalString (modes == "seq") ''
              substituteInPlace phoenix-2.0/tests/histogram/histogram-seq.c \
                --replace-fail '   return 0;' '   exit(0);'
              substituteInPlace phoenix-2.0/tests/kmeans/kmeans-seq.c \
                --replace-fail '    return 0;  ' '    exit(0);'
              substituteInPlace phoenix-2.0/tests/linear_regression/linear_regression-seq.c \
                --replace-fail '   return 0;' '   exit(0);'
              substituteInPlace phoenix-2.0/tests/matrix_multiply/matrix_multiply-seq.c \
                --replace-fail '   return 0;' '   exit(0);'
              substituteInPlace phoenix-2.0/tests/pca/pca-seq.c \
                --replace-fail '   return 0;' '   exit(0);'
              substituteInPlace phoenix-2.0/tests/string_match/string_match-seq.c \
                --replace-fail '   return 0;' '   exit(0);'
              substituteInPlace phoenix-2.0/tests/word_count/word_count-seq.c \
                --replace-fail '   return 0;' '   exit(0);'
            '';
            hardeningDisable = [ "all" ];
            disableFixup = true;
            nonPie = true;
            targetTriple = "x86_64-linux-gnu";
            libcName = "glibc";
          };
          mkStaticGlibc = modes: mkPhoenix {
            stdenv = glibcX86Pkgs.stdenv;
            buildPkgs = pkgs;
            name = "phoenix-x86_64-glibc-static-${modes}";
            inherit modes;
            appsToBuild = lib.filter (app: lib.elem app.benchmark [ "histogram" "kmeans" "linear_regression" "matrix_multiply" "pca" "string_match" "word_count" ]) apps;
            staticLink = true;
            staticSuffix = "-static-glibc";
            optimization = "-O2";
            extraCFlags = [ "-fno-stack-protector" "-pthread" "-L${glibcX86Pkgs.glibc.static}/lib" ];
            extraPostPatch = ''
              substituteInPlace phoenix-2.0/tests/string_match/string_match-pthread.c \
                --replace-fail '    srand( (unsigned)time( NULL ) );' '    srand(1);' \
                --replace-fail '    gettimeofday(&starttime,0);' '    memset(&starttime, 0, sizeof(starttime));' \
                --replace-fail '    gettimeofday(&endtime,0);' '    memset(&endtime, 0, sizeof(endtime));'
              substituteInPlace phoenix-2.0/tests/word_count/word_count-pthread.c \
                --replace-fail '   gettimeofday(&starttime,0);' '   memset(&starttime, 0, sizeof(starttime));' \
                --replace-fail '   gettimeofday(&endtime,0);' '   memset(&endtime, 0, sizeof(endtime));' \
                --replace-fail '   return 0;
}' '   fflush(stdout);
   return 0;
}'
            '';
            hardeningDisable = [ "all" ];
            targetTriple = "x86_64-linux-gnu";
            libcName = "glibc";
          };
        in
        let
          muslPackages = {
            phoenix-input-data = phoenixData;
            phoenix-input-data-histogram = phoenixDataPackages.histogram;
            phoenix-input-data-linear-regression = phoenixDataPackages.linear-regression;
            phoenix-input-data-string-match = phoenixDataPackages.string-match;
            phoenix-input-data-word-count = phoenixDataPackages.word-count;

            phoenix-x86_64-musl-static-seq = mkMusl "seq" "" "-O2";
            phoenix-x86_64-musl-static-pthread = mkMusl "pthread" "" "-O2";
            phoenix-x86_64-musl-static-all = mkMusl "all" "" "-O2";

            phoenix-x86_64-musl-dynamic-seq = mkDynamicMusl "seq";
            phoenix-x86_64-musl-dynamic-pthread = mkDynamicMusl "pthread";
            phoenix-x86_64-musl-dynamic-all = mkDynamicMusl "all";

            phoenix-x86_64-glibc-dynamic-seq = mkDynamicGlibc "seq";
            phoenix-x86_64-glibc-dynamic-pthread = mkDynamicGlibc "pthread";
            phoenix-x86_64-glibc-static-pthread = mkStaticGlibc "pthread";

            phoenix-x86_64-musl-static-seq-debug = mkMusl "seq" "-debug" "-O0";
            phoenix-x86_64-musl-static-all-benchmark = mkMusl "all" "-benchmark" "-O3";
          };
          nativePackages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
            phoenix-seq = mkNative "seq";
            phoenix-pthread = mkNative "pthread";
            phoenix-all = mkNative "all";
          };
        in
        muslPackages // nativePackages // {
          default = if pkgs.stdenv.hostPlatform.isx86_64
            then nativePackages.phoenix-all
            else muslPackages.phoenix-x86_64-musl-static-all;
        });

      checks = forAllSystems (pkgs: system:
        let
          pkg = self.packages.${system}.phoenix-x86_64-musl-static-seq;
          histogramData = self.packages.${system}.phoenix-input-data-histogram;
        in
        {
          phoenix-x86_64-musl-static-histogram-seq = pkgs.runCommand "check-phoenix-x86_64-musl-static-histogram-seq" {
            nativeBuildInputs = with pkgs; [ file binutils gnugrep ];
          } ''
            set -eu
            file ${pkg}/bin/histogram-seq-static-musl | tee file.out
            grep -q 'ELF 64-bit LSB executable, x86-64' file.out
            grep -q 'statically linked' file.out

            readelf -h ${pkg}/bin/histogram-seq-static-musl | tee readelf-h.out
            grep -q 'Type:.*EXEC' readelf-h.out

            readelf -l ${pkg}/bin/histogram-seq-static-musl | tee readelf-l.out
            if grep -q INTERP readelf-l.out; then
              echo 'unexpected INTERP program header' >&2
              exit 1
            fi

            test -e ${pkg}/bin/histogram-seq-v2-static-musl
            test ! -e ${pkg}/data
            test -e ${histogramData}/histogram_datafiles/small.bmp
            test -e ${pkg}/manifest.json
            touch $out
          '';
        });
    };
}
