
$arguments = Makr.getArgs()

$localDir = File.dirname($arguments.scriptFile)
$buildDir = $arguments.arguments[0]
$target = $arguments.arguments[1]


def configure(build)
  compilerConfig = build.makeNewConfig("CompileTask")
  compilerConfig.clear()
  compilerConfig["compiler"] = "g++"
  compilerConfig["compiler.includePaths"] = " -I" + $localDir + "/src" + " -I/usr/lib/qt3/include"
  compilerConfig["linker"] = "g++"
  compilerConfig["linker.libs"] = " -lX11 -lqt-mt"
  compilerConfig["linker.libPaths"] = "-L/usr/lib/qt3/lib64"
  Makr::PkgConfig.addCFlags(compilerConfig, "libpng")
  Makr::PkgConfig.addLibs(compilerConfig, "libpng")

  mocConfig = build.makeNewConfig("MocTask")
  mocConfig.clear()
  mocConfig["moc"] = "/usr/lib/qt3/bin/moc"
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
    tasks = Makr.applyGenerators(allCPPFiles, [Makr::CompileTaskGenerator.new(build, "CompileTask")])
    allHeaderFiles = Makr::FileCollector.collect($localDir + "/src/", "*.{h}", true)
    tasks.concat(Makr.applyGenerators(allHeaderFiles, [Makr::MocTaskGenerator.new(build, "CompileTask", "MocTask")]))

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
  end
end
