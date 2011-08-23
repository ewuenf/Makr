
arguments = Makr.getArgs()

localDir = File.dirname(arguments.scriptFile)
buildDir = arguments.arguments[0]
target = arguments.arguments[1]



def configure(build, localDir)
  build.clearConfigs()
  compilerConfig = build.makeNewConfig("CompileTask")
  compilerConfig["compiler"] = "g++"
  compilerConfig["compiler.includePaths"] = " -I" + localDir + "/src"
  compilerConfig["linker"] = "g++"
end


if(target == "clean")
  system("rm -f " + buildDir + "/*")
else
  # first get build (maybe this can be a global variable already)
  build = Makr::Build.new(buildDir)
  if build.configs.empty? then
    configure(build, localDir)
  end

  allFiles = Makr::FileCollector.collect(localDir + "/src/", "*.{cpp,cxx}", true)
  tasks = Makr.applyGenerators(allFiles, [Makr::CompileTaskGenerator.new(build, "CompileTask")])
  myProgramTask = Makr.makeProgram(buildDir + "/myProgram", build, tasks)

  # set special options for a single task
  compileTaskName = Makr::CompileTask.makeName(localDir + "/src/A.cpp")
  if (build.hasTask?(compileTaskName)) then
    task = build.getTask(compileTaskName)
    specialConf = build.makeNewConfigForTask(compileTaskName + "_Conf", task)
    if (not (specialConf["compiler.includePaths"]).include?(" -I/usr/include") ) then
      specialConf["compiler.includePaths"] += " -I/usr/include"
    end
  end

  updateTraverser = Makr::UpdateTraverser.new(2)
  updateTraverser.traverse(myProgramTask)

  build.save()
end
