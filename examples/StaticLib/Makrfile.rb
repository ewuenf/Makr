
$arguments = Makr.getArgs()

$localDir = File.dirname($arguments.scriptFile)
$buildDir = $arguments.arguments[0]
$target = $arguments.arguments[1]


def configure(build)
  compilerConfig = build.makeNewConfig("CompileTask")
  compilerConfig.clear()
  compilerConfig["compiler"] = "g++"
  compilerConfig["compiler.includePaths"] = " -I" + $localDir + "/src"
end


if($target == "clean")
  system("rm -f " + $buildDir + "/*")
else
  # first get build
  build = Makr.loadBuild(Makr.cleanPathName($buildDir))

  # then use build block concept to ensure the build is saved
  build.saveAfterBlock do
    
    configure(build) #if $build.configs.empty?

    allCPPFiles = Makr::FileCollector.collect($localDir + "/src/", "*.{cpp,cxx}", true)
    tasks = Makr.applyGenerators(allCPPFiles, [Makr::CompileTaskGenerator.new(build, build.getConfig("CompileTask"))])

    myStaticLibTask = Makr.makeStaticLib($buildDir + "/libtest.a", build, tasks, nil)

    build.nrOfThreads = 2
    build.build()

  end
end
