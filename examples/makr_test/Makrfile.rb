
$arguments = Makr.getArgs()

$localDir = File.dirname($arguments.scriptFile)
$buildDir = $arguments.arguments[0]
$target = $arguments.arguments[1]


def configure(build)
  compilerConfig = build.makeNewConfig("CompileTask")
  compilerConfig.clear()
  compilerConfig["compiler"] = "g++"
  compilerConfig["compiler.includePaths"] = " -I" + $localDir + "/src"
  compilerConfig["linker"] = "g++"
  compilerConfig["linker.libs"] = " -lX11 "
  Makr::PkgConfig.addCFlags(compilerConfig, "libpng")
  Makr::PkgConfig.addLibs(compilerConfig, "libpng")
end


if($target == "clean")
  system("rm -f " + buildDir + "/*")
else
  # first get build
  build = Makr.loadBuild(Makr.cleanPathName($buildDir))
  configure(build) #if $build.configs.empty?

  allFiles = Makr::FileCollector.collect($localDir + "/src/", "*.{cpp,cxx}", true)
  #allFiles = Makr::FileCollector.collectExclude(localDir + "/src/", "*", "*.h", true)
  tasks = Makr.applyGenerators(allFiles, [Makr::CompileTaskGenerator.new(build, "CompileTask")])
  #tasks.concat(Makr.applyGenerators(localDir + "/src/myfile.txtcpp", [Makr::CompileTaskGenerator.new(build, "CompileTask")]) # single file usage
  myProgramTask = Makr.makeProgram($buildDir + "/myProgram", build, tasks, "CompileTask")


  # set special options for a single task
  compileTaskName = Makr::CompileTask.makeName($localDir + "/src/A.cpp")
  if(build.hasTask?(compileTaskName)) then
    task = build.getTask(compileTaskName)
    specialConf = build.makeNewConfigForTask(compileTaskName + "_Conf", task)
    if (not (specialConf["compiler.includePaths"]).include?(" -I/usr/include") ) then
      specialConf["compiler.includePaths"] += " -I/usr/include"
    end
  end

  #build.nrOfThreads = 2
  build.build()

  Makr.saveBuild(build)
end
