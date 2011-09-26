# Nothing in this file is mandatory, everything is up the the users choice of organizing things,
# it is just provided as (a not very good) example of doing a build. The user could for example
# use functions and classes to organize it all.


# decompose arguments
$arguments = Makr.getArgs()
$localDir = File.dirname($arguments.scriptFile)
$buildDir = $arguments.arguments[0]
$target = $arguments.arguments[1]

# implement a simple clean target
if($target == "clean")
  system("rm -f " + $buildDir + "/*")
  exit
end

# when we're not cleaning, we build:

# first load build caches etc.
build = Makr.loadBuild($buildDir)

# then use build block concept to ensure the build is saved after block has run through
build.saveAfterBlock do

  # create some Config instances for use during build (they may already exist)
  compilerConfig = build.makeNewConfig("CompileTask")
  compilerConfig.clear()
  compilerConfig["compiler"] = "g++"
  compilerConfig["compiler.includePaths"] = " -I" + $localDir + "/src"


  # then we collect all relevant files and apply generators to them
  allCPPFiles = Makr::FileCollector.collect($localDir + "/src/", "*.{cpp,cxx}", true)
  # compilerConfig could be specified directly here, but we use the name
  # (as the configuration part of the script may be far away)
  tasks = Makr.applyGenerators(allCPPFiles, [Makr::CompileTaskGenerator.new(build, build.getConfig("CompileTask"))])


  # so this Makrfile.rb is going to build a static lib
  myStaticLibTask = Makr.makeStaticLib($buildDir + "/libtest.a", build, tasks, nil)


  # finally, just build the whole thing (only building things, that have changed since last call)
  # we could use "build.nrOfThreads = <number>" here to specify the number of threads to be used upon building
  build.nrOfThreads = 4
  build.build()
end

