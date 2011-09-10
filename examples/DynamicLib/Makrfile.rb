
$arguments = Makr.getArgs()

$localDir = File.dirname($arguments.scriptFile)
$buildDir = $arguments.arguments[0]
$target = $arguments.arguments[1]


def configure(build)
  compilerConfig = build.makeNewConfig("CompileTask")
  compilerConfig.clear()
  compilerConfig["compiler"] = "g++"
  compilerConfig["compiler.includePaths"] = " -I" + $localDir + "/src"
  compilerConfig["compiler.cFlags"] = " -fPIC "
end


if($target == "clean")
  system("rm -f " + buildDir + "/*")
else
  # first get build
  build = Makr.loadBuild(Makr.cleanPathName($buildDir))
  configure(build) #if $build.configs.empty?

  allCPPFiles = Makr::FileCollector.collect($localDir + "/src/", "*.{cpp,cxx}", true)
  tasks = Makr.applyGenerators(allCPPFiles, [Makr::CompileTaskGenerator.new(build, "CompileTask")])

  myStaticLibTask = Makr.makeDynamicLib($buildDir + "/libtest.so.1.2.3", build, tasks, nil)

  build.nrOfThreads = 2
  build.build()

  Makr.saveBuild(build)
end
