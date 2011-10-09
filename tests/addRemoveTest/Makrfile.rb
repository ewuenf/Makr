# decompose arguments
$arguments = Makr.getArgs()
$localDir = File.dirname($arguments.scriptFile)
$buildDir = $arguments.arguments[0]
$target = $arguments.arguments[1]


def buildAll()

  # first load build caches etc.
  build = Makr.loadBuild($buildDir)

  # then use build block concept to ensure the build is saved after block has run through
  build.saveAfterBlock do

    # create some Config instances for use during build (they may already exist), this example uses a qt3 setup
    compilerConfig = build.makeNewConfig("CompileTask")
    compilerConfig.clear()
    compilerConfig["compiler"] = "g++"
    compilerConfig["compiler.includePaths"] = " -I" + $localDir + "/src"
    compilerConfig["linker"] = "g++"


    # then we collect all relevant files and apply generators to them
    allCPPFiles = Makr::FileCollector.collect($localDir + "/src/", "*.{cpp,cxx}", true)
    # compilerConfig could be specified directly here, but we use the name
    # (as the configuration part of the script may be far away)
    tasks = Makr.applyGenerators(allCPPFiles, [Makr::CompileTaskGenerator.new(build, build.getConfig("CompileTask"))])

    # so this Makrfile.rb is going to build a program
    myProgramTask = Makr.makeProgram($buildDir + "/myProgram", build, tasks, build.getConfig("CompileTask"))

    # finally build with nr of processors
    build.build()
  end
end

# implement a simple clean target
if($target == "clean")
  system("rm -f " + $buildDir + "/*")
else
  buildAll()
end
