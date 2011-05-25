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

  myProgramTask = Makr::ProgramGenerator.generate(localDir + "/src/", "*.cpp", build, buildDir + "/myProgram")

  updateTraverser = Makr::UpdateTraverser.new(1)
  updateTraverser.traverse(myProgramTask)

  build.dumpTaskHash()
end