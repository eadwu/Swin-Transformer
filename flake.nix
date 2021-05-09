{
  description = "Swin-Transformer";

  # General Repositories
  inputs.nixpkgs = { type = "github"; owner = "NixOS"; repo = "nixpkgs"; };
  inputs.flake-compat = { type = "github"; owner = "edolstra"; repo = "flake-compat"; flake = false; };

  # Reproducible Python Environments
  inputs.mach-nix = { type = "github"; owner = "DavHau"; repo = "mach-nix"; flake = false; };

  # Swin Transformer External Dependencies
  # https://github.com/NVIDIA/apex/issues/1091
  inputs.nvidia-apex = { type = "github"; owner = "NVIDIA"; repo = "apex"; ref = "a651e2c24ecf97cbf367fd3f330df36760e1c597"; flake = false; };

  outputs = { self, nixpkgs, ... }@inputs:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);

      config = { allowUnfree = true; };
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit config system; overlays = [ self.overlay ]; });
    in
    {

      overlay = final: prev:
        with final; {

          cudatoolkit = final.cudatoolkit_10_1;
          cudnn = final.cudnn_cudatoolkit_10_1;
          nccl = prev.nccl.override { cudatoolkit = final.cudatoolkit_10_1; };

        };

      devShell = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
          mach-nix = import inputs.mach-nix {
            inherit pkgs;
            python = "python37";

            # Latest dependency resolution chain as of May 08, 2021
            pypiDataRev = "e674adca06b80ff3831e28cdcff041c44b960bb4";
            pypiDataSha256 = "0p90r8daaklp9dqy6ik1wf1c0y32hr2w7rz6ba3g7xb7vfgz17pf";
          };

          nvidia-apex = mach-nix.buildPythonPackage
            rec
            {
              pname = "nvidia-apex";
              version = builtins.substring 0 8 inputs.nvidia-apex.lastModifiedDate;
              src = inputs.nvidia-apex;

              CUDA_HOME = with mach-nix.nixpkgs; symlinkJoin {
                name = "${cudatoolkit_10_2.name}-joined";
                paths = [ cudatoolkit_10_2 cudatoolkit_10_2.lib ];

                postBuild = ''
                  # cudatoolkit_10_2.out has $out/lib as a symlink...
                  for f in ${cudatoolkit_10_2.lib}/lib/libcudart*; do
                    ln -sf $f $out/lib/$(basename "$f")
                  done
                '';
              };

              setupPyGlobalFlags = [
                "--cpp_ext"
                "--cuda_ext"
              ];

              nativeBuildInputs =
                with pkgs;
                [
                  which
                  # Faster BuildExtension backend
                  ninja
                ];

              requirements = ''
                # torch
                torch==1.7.1
              '' + builtins.readFile (inputs.nvidia-apex + "/requirements.txt");
            };

          env = mach-nix.mkPython
            rec {
              # pytorch == torch
              requirements = ''
                torch==1.7.1
                torchvision==0.8.2
                timm==0.3.2
                opencv-python==4.4.0.46
                termcolor==1.1.0
                yacs==0.1.8
              '';

              providers = {
                _default = "wheel,sdist,nixpkgs";
              };

              packagesExtra = [ nvidia-apex ];

              overridesPost = [ (final: prev: {
                # Resolve conflicts with `nvidia-apex`'s PyTorch build-time dependency
                torch = final.pkgs.lib.hiPrio (prev.torch);
              }) ];
            };

          envOpenGL = env.override (
            { makeWrapperArgs ? [], ... }:
            {
              makeWrapperArgs = makeWrapperArgs ++ [
                "--prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath
                  # CUDA Libraries for pytorch
                  (pkgs.cudatoolkit.all ++ pkgs.cudnn.all
                  # Expose NVIDIA driver in NixOS
                  ++ [ pkgs.addOpenGLRunpath.driverLink ])}"
              ];
            } );
        in
        pkgs.mkShell {
          buildInputs = [ envOpenGL ];

          # Direnv (Lorri) Support
          PYTHON_ENV = envOpenGL.out;
        });

    };
}
