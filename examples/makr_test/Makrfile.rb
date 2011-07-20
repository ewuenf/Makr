
arguments = Makr.getArgs()

localDir = File.dirname(arguments.scriptFile)
buildDir = arguments.arguments[0]
target = arguments.arguments[1]


def configure(build, localDir)
  compilerConfig = build.makeNewConfig("CompileTask")
  compilerConfig["compiler.includePaths"] = " -I" + localDir + "/src"
  puts "Saving build"
  build.save()
end


if(target == "clean")
  system("rm -f " + buildDir + "/*")
else
  # first get build (maybe this can be a global variable already)
  build = Makr::Build.new(buildDir)
  if not build.hasConfig?("CompileTask") then
    configure(build, localDir)
  end

  myProgramTask = Makr::ProgramGenerator.generate(localDir + "/src/", "*.{cpp,cxx,c}", build, buildDir + "/myProgram", "CompileTask")

  # set special options for a single task
  #compileTaskName = Makr::CompileTask.makeName(localDir + "/src/A.cpp")
  #if (build.hasTask?(compileTaskName)) then
  #  task = build.getTask(compileTaskName)
  #  specialConf = build.makeNewConfig("A.cpp_Conf", task.configName)
  #  specialConf["compiler.includePaths"] += " -I/usr/include"
  #end

  #updateTraverser = Makr::UpdateTraverser.new(2)
  #updateTraverser.traverse(myProgramTask)

  build.save()
end
