# Nothing in this file is mandatory, everything is up the the users choice of organizing things,
# it is just provided as (a not very good) example of doing a build. The user could for example
# use functions and classes to organize it all.


# At first, we need to load a tool chain (which is implemented as an extension). The exact
# usage may differ for another tool chain, the following Makrfile.rb uses gcc command line
# arguments. For every extension there should be enough documentation or examples to guide
# the user through.
Makr.loadExtension("ToolChainLinuxGcc")

# then we load some further extensions
Makr.loadExtension("Qt")
Makr.loadExtension("pkg-config")
# The following is an extension, which is intrusive into main Makr classes 
# (like Build, FileTask,...), so use only when really helpful
Makr.loadExtension("SourceStats")

Makr.loadExtension("ConfigH")


# then decompose arguments
$arguments = Makr.getArgs()
$localDir = File.dirname($arguments.scriptFile)
$buildDir = $arguments.arguments[0]
$target = $arguments.arguments[1]


puts "target in makr_test: #{$target}"


def buildAll()

  configH = Makr::ConfigH.new($localDir + "/src/config.h")
  configH.addDefine("TEST_DEF", "just a test")
  configH.generateFile()
  
  # first load build caches etc.
  build = Makr.loadBuild($buildDir)

  # then use build block concept to ensure the build is saved after block has run through
  build.saveAfterBlock do

    # create some Config instances for use during build (they may already exist), this example uses a qt3 setup
    compilerConfig = build.makeNewConfig("CompileTask")
    compilerConfig.clear()
    compilerConfig["compiler"] = "g++" # this is purely optional, as the default value is "g++ "
    # setting values of the configuration hash can be done with " = " or " += ", regardless of wether they have been
    # set before, its just a matter of overwriting or adding configuration strings
    compilerConfig["compiler.includePaths"] += " -I" + $localDir + "/src" + " -I/usr/lib/qt3/include"
    compilerConfig["linker"] = "g++"
    compilerConfig["linker.libs"] = " -lX11"
    # use pkg-config to simplify config tasks
    Makr::PkgConfig.addCFlags(compilerConfig, "libpng")
    Makr::PkgConfig.addLibs(compilerConfig, "libpng")
    Makr::PkgConfig.addCFlags(compilerConfig, "QtCore")
    Makr::PkgConfig.addLibs(compilerConfig, "QtCore")


    # then we collect all relevant files and apply generators to them
    allCPPFiles = Makr::FileCollector.collect($localDir + "/src/", "*.{cpp,cxx}", true)
    # compilerConfig could be specified directly here, but we use the name
    # (as the configuration part of the script may be far away)
    tasks = Makr.applyGenerators(allCPPFiles, [Makr::CompileTaskGenerator.new(build, build.getConfig("CompileTask"))])
    allHeaderFiles = Makr::FileCollector.collect($localDir + "/src/", "*.{h}", true)
    tasks.concat(
      Makr.applyGenerators(allHeaderFiles, [Makr::MocTaskGenerator.new(build, build.getConfig("CompileTask"))])
                )

    # so this Makrfile.rb is going to build a program
    myProgramTask = Makr.makeProgram($buildDir + "/myProgram", build, tasks, build.getConfig("CompileTask"))

    #myProgramTask.printDependencies()
    #exit 0

    # set special options for a single task
    compileTaskName = Makr::CompileTask.makeName($localDir + "/src/A.cpp")
    if(build.hasTask?(compileTaskName)) then
      task = build.getTask(compileTaskName)
      specialConf = build.makeNewConfigForTask(compileTaskName + "_Conf", task)
      specialConf.copyAddUnique("compiler.includePaths", " -I/usr/include")
    end

    # finally, just build the whole thing (only building things, that have changed since last call)
    # we could use "build.nrOfThreads = <number>" here to specify the number of threads to be used upon building
    #build.nrOfThreads = 1 # a single thread can be helpful for debugging
    build.build()
  end
end

# implement a simple clean target
if($target == "clean")
  system("rm -rf #{$buildDir} #{$localDir + "/src/config.h"}")
else
  buildAll()
end
