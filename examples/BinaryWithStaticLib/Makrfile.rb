# Nothing in this file is mandatory, everything is up the the users choice of organizing things,
# it is just provided as (a not very good) example of doing a build. The user could for example
# use functions and classes to organize it all.


# in this file we want to show how to create a static lib and then link everything together
# to a program.



# At first, we need to load a tool chain (which is implemented as an extension). The exact
# usage may differ for another tool chain, the following Makrfile.rb uses gcc command line
# arguments. For every extension there should be enough documentation or examples to guide
# the user through.
Makr.loadExtension("ToolChainLinuxGcc")


# decompose arguments
$arguments = Makr.getArgs()
$localDir = File.dirname($arguments.scriptFile)
$buildDir = $arguments.arguments[0]
$target = $arguments.arguments[1]


puts "target in StaticLib: #{$target}"


def buildAll()
  
  # first load build caches etc.
  build = Makr.loadBuild($buildDir)

  # then use the build block concept to ensure the build is saved after block has run through
  build.saveAfterBlock do

    # create some Config instances for use during build (they may already exist)
    compilerConfig = build.makeNewConfig("CompileTask")
    compilerConfig.clear()
    compilerConfig["compiler"] = "g++"
    compilerConfig["compiler.includePaths"] = " -I" + $localDir + "/src/lib"

    # we could use "build.nrOfThreads = <number>" here to specify the number of threads to be used upon building
    build.nrOfThreads = 4

    # then we collect all files relevant to the static lib and apply generators to them
    allLibFiles = Makr::FileCollector.collect($localDir + "/src/lib", "*.{cpp,cxx}", true)
    # compilerConfig could be specified directly here, but we use the name
    # (as the configuration part of the script may be far away)
    tasks = Makr.applyGenerators(allLibFiles, [Makr::CompileTaskGenerator.new(build, build.getConfig("CompileTask"))])
    # construct the static lib task
    myStaticLibTask = Makr.makeStaticLib($buildDir + "/libtest.a", build, tasks, nil)
    # and then build it
    build.build(myStaticLibTask)

    # we can use a generator directly (if we know that we need only one), by calling its generate-function with a file name
    # a generator always returns an array, so we name it mainCompileTasks although the array in this case contains only one
    # member
    mainCompileTasks = Makr::CompileTaskGenerator.new(build, build.getConfig("CompileTask")).generate($localDir + "/src/main.cpp")

    # we construct the dependent tasks for the program (we use the first entry of mainCompileTasks, it should only have one)
    programDeps = [myStaticLibTask, mainCompileTasks[0]]
    # then we construct the program task
    myProgramTask = Makr.makeProgram($buildDir + "/myProgram", build, programDeps, build.getConfig("CompileTask"))
    # then we build the program
    build.build(myProgramTask)
  end
end

# implement a simple clean target
if($target == "clean")
  system("rm -f " + $buildDir + "/*")
else
  buildAll()
end

