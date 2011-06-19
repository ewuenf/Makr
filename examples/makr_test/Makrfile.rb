
arguments = Makr.getArgs()

localDir = File.dirname(arguments.scriptFile)
buildDir = arguments.arguments[0]
target = arguments.arguments[1]

if(target == "clean")
  system("rm -f " + buildDir + "/*")
else
  # first get build (maybe this can be a global variable already)
  build = Makr::Build.new(buildDir)
  compilerConfig = Makr::CompileTask::Config.new
  compilerConfig.includePaths += " -I" + localDir + "/src"

  myProgramTask = Makr::ProgramGenerator.generate(localDir + "/src/", "*.{cpp,cxx,c}", build, buildDir + "/myProgram", compilerConfig)

  # set special options for a single compile task
  compileTaskName = Makr::CompileTask.makeName(localDir + "/src/A.cpp")
  if (build.hasTask?(compileTaskName)) then
    task = build.getTask(compileTaskName)
    specialConfig = compilerConfig.clone
    specialConfig.includePaths += " -I/usr/include"
    task.setConfig(specialConfig)
  end

  updateTraverser = Makr::UpdateTraverser.new(1)
  updateTraverser.traverse(myProgramTask)

  build.save()
end
