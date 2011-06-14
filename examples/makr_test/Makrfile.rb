puts $makrFilePath
puts $commandLineArgs

localDir = File.dirname($makrFilePath)
buildDir = $commandLineArgs[0]
target = $commandLineArgs[1]

if(target == "clean")
  system("rm -f " + buildDir + "/*")
else
  # first get build (maybe this can be a global variable already)
  build = Makr::Build.new(buildDir)
  build.globalConfig.includePaths += " -I" + localDir + "/src"

  myProgramTask = Makr::ProgramGenerator.generate(localDir + "/src/", "*.{cpp,cxx,c}", build, buildDir + "/myProgram")

  sourceName = Makr::CompileTask.makeName(localDir + "/src/A.cpp")
  config = build.taskHash[sourceName].getLocalConfig
  config.includePaths = build.globalConfig.includePaths + " -I/usr/include"

  myProgramTask.printDependencies("  ")

  updateTraverser = Makr::UpdateTraverser.new(1)
  updateTraverser.traverse(myProgramTask)

  build.dumpTaskHashCache()
end
