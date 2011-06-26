#!/usr/bin/ruby


# This is my own home-brewn ruby-based build tool.
# I hereby name it "makr" and it will read "Makrfiles", uenf!
#
# Documentation is sparse as source is short and a number
# of examples are provided.




require 'find'
require 'thread'
require 'md5'
require 'logger'






module Makr







  
  # slightly modified from https://github.com/fizx/thread_pool #########################################
  class ThreadPool
    class Executor
      attr_reader :active

      def initialize(queue, mutex)
        @thread = Thread.new do
          loop do
            mutex.synchronize { @tuple = queue.shift }
            if @tuple
              args, block = @tuple
              @active = true
              begin
                block.call(*args)
              rescue Exception => e
                error e.message
                error e.backtrace.join("\n")
              end
              block.complete = true
            else
              @active = false
              sleep 0.01
            end
          end
        end
      end

      def close
        @thread.exit
      end
    end

    attr_accessor :queue_limit

    # Initialize with number of threads to run
    def initialize(count, queue_limit = 0)
      @mutex = Mutex.new
      @executors = []
      @queue = []
      @queue_limit = queue_limit
      @count = count
      count.times { @executors << Executor.new(@queue, @mutex) }
    end

    # Runs the block at some time in the near future
    def execute(*args, &block)
      init_completable(block)

      if @queue_limit > 0
        sleep 0.01 until @queue.size < @queue_limit
      end

      @mutex.synchronize do
        @queue << [args, block]
      end
    end

    # Runs the block at some time in the near future, and blocks until complete
    def synchronous_execute(*args, &block)
      execute(*args, &block)
      sleep 0.01 until block.complete?
    end

    # Size of the task queue
    def waiting
      @queue.size
    end

    # Size of the thread pool
    def size
      @count
    end

    # Kills all threads
    def close
      @executors.each {|e| e.close }
    end

    # Sleeps and blocks until the task queue is finished executing
    def join
      sleep 0.01 until @queue.empty? && @executors.all?{|e| !e.active}
    end

  protected
    def init_completable(block)
      block.extend(Completable)
      block.complete = false
    end

    module Completable
      def complete=(val)
        @complete = val
      end

      def complete?
        !!@complete
      end
    end
  end

  # end of thread pool implementation ########################################################################################


  




  # own classes follow


  
  # logging 
  @log = Logger.new(STDOUT)
  def self.log()
    @log
  end


  # FIXME build abort should work from wherever
  def self.abortBuild()
    Makr.log.fatal("Aborting build process.")
    Kernel.exit! 1  # does this work ???
  end


  

  # Basic class and concept representing a node in the dependency tree and any type of action that
  # needs to be performed (such as a versioning system update or somefingelse)
  class Task
    
    attr_reader :name, :dependencies, :dependantTasks
    # these are used by the multi-threaded UpdateTraverser
    attr_accessor :mutex, :updateMark, :dependenciesUpdatedCount, :dependencyWasUpdated

    
    def initialize(name)
      @name = name
      @dependencies = Array.new
      @dependantTasks = Array.new

      # regarding the meaning of these see class UpdateTraverser
      @mutex = Mutex.new
      @updateMark = false
      @dependenciesUpdatedCount = 0
      @dependencyWasUpdated = false
    end

    
    def addDependency(otherTask)
      if(@dependencies.index(otherTask) == nil)
        @dependencies.push(otherTask)
        otherTask.dependantTasks.push(self)
      end
      # we dont do anything if a task wants to be added twice, they are unique, maybe we should log this
    end

    
    def removeDependency(otherTask)
      if(@dependencies.index(otherTask) != nil)
        otherTask.dependantTasks.delete(self)
        @dependencies.delete(otherTask)
      else
        raise "Trying to remove a non-existant dependency!" # here we definitely raise an exception
      end
    end

    
    def clearDependencies()
      Makr.log.debug("clearing deps in: " + @name)
      while not @dependencies.empty?
        removeDependency(@dependencies.first)
      end
    end

    
    def clearDependantTasks()
      while not @dependantTasks.empty?
        @dependantTasks.first.removeDependency(self)  # this deletes @dependantTasks.first implicitely (see above)
      end
    end

    
    def clearAll()
      clearDependencies()
      clearDependantTasks()
    end

    
    # every subclass should provide an "update()" function, that returns wether the target of the task was updated.
    # The default implementation returns false. This function gets called when at least a single dependecy was updated
    # or if there are no dependencies at all.
    def update() 
      false
    end

    
    # can be impletemented by subclasses indicating that this task is no longer valid due to a circumstance such as
    # a missing file
    def mustBeDeleted?()
      Makr.log.debug("mustBeDeleted?() default call.")
      false
    end

    def printDependencies(prefix)
      puts prefix + @name + " deps size: " + @dependencies.size.to_s
      @dependencies.each do |dep|
        dep.printDependencies(prefix + "  ")
      end
    end

    def cleanupBeforeDeletion()  # interface mainly for tasks generating targets
    end
    
  end


  

  class FileTask < Task

    attr_reader :fileName, :time, :size, :fileHash, :missingFileIsError # absolute path for fileName expected!

    # the boolean argument missingFileIsError can be used to indicate, if an update is necessary, if file is missing 
    # (which is the "false" case) or if it is an error and the build should abort
    def initialize(fileName, missingFileIsError = true)  # absolute path for fileName expected!
      @fileName = fileName
      Makr.log.debug("made file task with @fileName=\"" + @fileName + "\"")
      super(@fileName)
      # all file attribs stay uninitialized, so that first call to update returns true
      @time = @size = @fileHash = String.new
      @missingFileIsError = missingFileIsError
    end

    
    def update()
      if (not File.file?(@fileName))
        if(@missingFileIsError)
          Makr.log.fatal("file " + fileName + "  is unexpectedly missing!\n\n")
          Makr.abortBuild
        end
        Makr.log.info("FileTask " + fileName + " is missing, so update() is true.")
        return true;
      end
      retValue = false
      curTime = File.stat(@fileName).mtime
      if(@time != curTime)
        @time = curTime
        retValue = true
      end
      curSize = File.stat(@fileName).size
      if(@size != curSize)
        @size = curSize
        retValue = true
      end
      curHash = MD5.new(open(@fileName, 'rb').read).hexdigest
      if(@fileHash != curHash)
        @fileHash = curHash
        retValue = true
      end
      if retValue then
        Makr.log.info("file " + fileName + " has changed")
      end
      return retValue
    end

    
    # a missing file
    def mustBeDeleted?()
      if (not File.file?(@fileName))
        if(@missingFileIsError)
          Makr.log.info("mustBeDeleted?() is true for missing file: " + @fileName)
          return true;
        end
      end
      false
    end

  end


  





  # Represents a compiled source that has dependencies to included files (and any deps that a user may specify).
  # The input files are dependencies on FileTasks including the source itself. Another dependency exists on the
  # target object file, so that the task rebuilds, if that file was deleted or modified otherwise.
  class CompileTask < Task
    
    class Config

      # otherOptions is just an array of strings for arbitrary compiler arguments
      attr_accessor :compilerCommand, :cFlags, :defines, :includePaths, :otherOptions

      def initialize()
        @compilerCommand = "g++ "                        # default val
        @cFlags = @defines = @includePaths = String.new  # default is empty
        @otherOptions = Array.new
      end

      
      def makeCompilerCallString()
        retString = @compilerCommand + " " + @cFlags + " " + @defines + " " + @includePaths + " "
        @otherOptions.each { |option| retString += " " + option}
        retString
      end

      
      def clone() # ensure a deep copy
        retConf = Config.new
        retConf.compilerCommand = @compilerCommand.clone
        retConf.cFlags = @cFlags.clone
        retConf.defines = @defines.clone
        retConf.includePaths = @includePaths.clone
        retConf.otherOptions = @otherOptions.clone
        retConf
      end

      
      def == (otherConf)
        return     (@compilerCommand == otherConf.compilerCommand) && (@cFlags == otherConf.cFlags            ) && \
                   (@defines         == otherConf.defines        ) && (@includePaths == otherConf.includePaths) && \
                   (@otherOptions    == otherConf.otherOptions   )
      end
    end

    
    # class vars and functions
    @@checkOnlyUserHeaders = false
    def self.checkOnlyUserHeaders
      @@checkOnlyUserHeaders
    end

    
    # make a unique name for CompileTasks out of the fileName which is to be compiled
    def self.makeName(fileName)
      "CompileTask__" + fileName
    end


    # the absolute path of the input and output file of the compilation
    attr_reader :fileName, :objectFileName, :compileTarget, :config

    
    # build contains the global configuration, see Build.globalConfig and class Config
    def initialize(fileName, build, config)
      @fileName = fileName
      @build = build
      @config = config

      # now we need a unique name for this task. As we're defining a FileTask as dependency to fileName
      # and a FileTask on the @objectFileName to ensure a build of the target if it was deleted or
      # otherwise modified (whatever you can think of here), we create a unique name
      super(CompileTask.makeName(@fileName))
      Makr.log.debug("made CompileTask with @name=\"" + @name + "\"")

      # we just keep it simple for now and add a ".o" to the given fileName, as we cannot safely replace a suffix
      @objectFileName = @build.buildPath + "/" + File.basename(@fileName) + ".o"
      # now add a dependency task on the target object file
      if not @build.hasTask?(@objectFileName) then
        @compileTarget = FileTask.new(@objectFileName, false)
        @build.addTask(@objectFileName, @compileTarget)
      else
        @compileTarget = @build.getTask(@objectFileName)
      end
      # the following first deletes all deps and then constructs them including the @compileTarget
      buildDependencies() 
    end

    def setConfig(config)
      if @config != config then
        @config = config
        buildDependencies()
      end
    end
    
    def buildDependencies()
      clearDependencies()
      # we use the compiler for now, but maybe fastdep is worth a look / an adaption
      # we are excluding system headers for now (option "-MM"), but that may not bring performance, then use option "-M"
      dependOption = " -M "
      if @@checkOnlyUserHeaders
        dependOption = " -MM "
      end
      depCommand = @config.makeCompilerCallString() + " " + dependOption + " " + @fileName
      Makr.log.info("Executing compiler to check for dependencies in CompileTask: \"" + @fileName + "\"\n\t" + depCommand)
      compilerPipe = IO.popen(depCommand)  # in ruby >= 1.9.2 we could use Open3.capture2(...) for this purpose
      dependencyLines = compilerPipe.readlines
      if dependencyLines.empty?
        Makr.log.error("error in CompileTask: \"" + @fileName + "\" making dependencies failed, check file!")
        Makr.abortBuild # should this be a hard error or should we continue gracefully?
      end
      dependencyFiles = Array.new
      dependencyLines.each do |depLine|
        if depLine.include?('\\') # remove newline *and* backslash on each line, if present
          depLine.chop!.chop!  # double chop needed
        end        
        if depLine.include?(':') # the "xyz.o"-target specified by the compiler in the "Makefile"-rule needs to be skipped
          splitArr = depLine.split(": ")
          dependencyFiles.concat(splitArr[1...splitArr.length])
        else
          dependencyFiles.concat(depLine.split(" "))
        end
      end
      dependencyFiles.each do |depFile|
        depFile.strip!
        if @build.hasTask?(depFile) then
          task = @build.getTask(depFile)
          if not @dependencies.include?(task)
            addDependency(task)
          end
        else
          task = FileTask.new(depFile)
          @build.addTask(depFile, task)
          addDependency(task) # dependencies cannot contain task if everything is coded right
        end
      end
      # need to do this or the compile task dep will be lost each time we build them deps here
      addDependency(@compileTarget)                                    
    end

    
    def update()
      # we always want this if any dependency changed, as this could mean changed dependencies due to new includes etc.
      buildDependencies()                          
      # construct compiler command and execute it
      compileCommand = @config.makeCompilerCallString() + " -c " + " " + @fileName + " -o " + @objectFileName
      Makr.log.info("Executing compiler in CompileTask: \"" + @fileName + "\"\n\t" + compileCommand)
      successful = system(compileCommand)
      if not successful
        Makr.log.fatal("compile error, exiting build process\n\n\n")
        abortBuild()
      end
      @compileTarget.update() # we call this to update file information on the compiled target
      return true # right now, we are always true (we could check for target equivalence or something else)
    end

    
    def cleanupBeforeDeletion()
      system("rm -f " + @objectFileName)
    end
    
  end



  
  class DynamicLibTask < Task
    # special dynamic lib thingies
    def initialize(libName)
      raise "Not implemented yet"
    end
  end



  
  class StaticLibTask < Task
    # special static lib thingies
    def initialize(libName)
      raise "Not implemented yet"
    end
  end


  

  class ProgramTask < Task

    attr_reader    :programName  # identifies the binary to be build, wants full path as usual
    attr_accessor  :compilerCommand
    attr_accessor  :lFlags       # special linker flags
    attr_accessor  :libPaths     # special linker paths
    attr_accessor  :libs         # libs to be linked to the binary

    
    # make a unique name for ProgramTasks out of the programName which is to be compiled
    def self.makeName(programName)
       "ProgramTask__" + programName
    end

    
    def initialize(programName, build)
      @programName = programName
      super(ProgramTask.makeName(@programName))
      @build = build
      Makr.log.debug("made ProgramTask with @name=\"" + @name + "\"")

      # TODO: we could load config from build dir? and use a subclass for config, as in CompileTask
      @compilerCommand = "g++ "
      @lFlags = @libPaths = @libs = String.new

      if not @build.hasTask?(@programName) then
        @compileTarget = FileTask.new(@programName, false)
        @build.addTask(@programName, @compileTarget)
      else
        @compileTarget = @build.getTask(@programName)
      end
      addDependency(@compileTarget)
    end
    

    def update()
      # build compiler command and execute it
      compileCommand = @compilerCommand + " " + @lFlags + " " + @libPaths + " " + @libs + " -o " + @programName
      @dependencies.each do |dep|
        if dep == @compileTarget then
          next
        end
        compileCommand += " " + dep.objectFileName
      end
      Makr.log.info("Building programTask \"" + @name + "\"\n\t" + compileCommand)
      system(compileCommand)  # TODO we dont check for return here. maybe we should?
      @compileTarget.update() # we call this to update file information on the compiled target
      return true # this is always updated
    end

    
    def cleanupBeforeDeletion()
      system("rm -f " + @programName)
    end
    
  end

  


  class Build

    attr_reader   :buildPath
    attr_reader   :taskHashCacheFile
    attr_accessor :mutex


    # build path should be absolute and is read-only once set in this "ctor"
    def initialize(buildPath) 
      @buildPath     = buildPath
      @buildPath.freeze # set readonly
      @buildPathMakrDir = @buildPath + "/.makr"
      if not File.directory?(@buildPathMakrDir)
        Dir.mkdir(@buildPathMakrDir)
      end

      @taskHash      = Hash.new            # maps task names to tasks (names are for example full path file names)
      @taskHashCache = Hash.new            # a cache for the task hash that is loaded below
      @taskHashCacheFile  = @buildPathMakrDir + "/taskHashCache.ruby_marshal_dump"  # where the task hash cache is stored to
      loadTaskHashCache()

      @mutex = Mutex.new
    end


    def hasTask?(taskName)
      mutex.synchronize do
        return (@taskHash.has_key?(taskName) or @taskHashCache.has_key?(taskName))
      end
    end


    def getTask(taskName)
      mutex.synchronize do
        if @taskHash.has_key?(taskName) then
          return @taskHash[taskName]
        elsif @taskHashCache.has_key?(taskName) then
          addTaskPrivate(taskName, @taskHashCache[taskName])  # we make a copy upon request
          return @taskHash[taskName]  
        else
          nil  # return nil, if not found (TODO raise an exception here?)
        end
      end
    end


    def addTask(taskName, task)
      mutex.synchronize do
        addTaskPrivate(taskName, task)
      end
    end

    
    def removeTask(taskName)
      mutex.synchronize do
        if @taskHash.has_key?(taskName) then # we dont bother about cache here, as cache is overwritten on save to disk
          @taskHash.delete(taskName)
        else
          raise "[makr] BUG: non-existant task removal requested!"
        end
      end
    end

    def save()
      dumpTaskHashCache()
    end

    def dumpTaskHashCache()
      mutex.synchronize do
        # then dump the hash (and not the cache!, this way we get overridden cache next time)
        File.open(@taskHashCacheFile, "wb") do |dumpFile|
          Marshal.dump(@taskHash, dumpFile)
        end
      end
    end


  private

    def addTaskPrivate(taskName, task)
      if @taskHash.has_key? taskName then
        Makr.log.warn("Build.addTaskPrivate, taskName exists already!: " + taskName)
        return
      end
      @taskHash[taskName] = task   # we dont bother about cache here, as cache is overwritten on save to disk
      # if a task is added all its dependencies are also added automatically, if it has em'
      addArr = task.dependencies.clone
      while not addArr.empty? do
        curTask = addArr.delete_at(0)
        if not @taskHash.has_key? curTask.name then
          @taskHash[curTask.name] = curTask
        end
        addArr.concat(curTask.dependencies.clone)
      end
    end
  
    def loadTaskHashCache()
      Makr.log.debug("trying to read task hash cache from " + @taskHashCacheFile)
      if File.file?(@taskHashCacheFile)
        Makr.log.debug("found task hash cache file, now restoring\n\n")
        File.open(@taskHashCacheFile, "rb") do |dumpFile|
          @taskHashCache = Marshal.load(dumpFile)        # load using Marshal (see dumpTaskHashCache)
        end
      else
      Makr.log.debug("could not find or open taskHash file, tasks will be setup new!\n\n")
      end
      cleanTaskHashCache()
    end
    

    def cleanTaskHashCache()
      # remove tasks that want to be deleted and their
      deleteArr = Array.new
      @taskHashCache.each do |key, value|
        if value.mustBeDeleted? then
          deleteArr.push(value)
        end
      end
      Makr.log.debug("cleanTaskHashCache(), number of tasks to be cleansed: " + deleteArr.size.to_s)
      while not deleteArr.empty? do
        task = deleteArr.delete_at(0)
        @taskHashCache.delete(task.name)
        deleteArr.concat(task.dependantTasks)
        task.cleanupBeforeDeletion()
      end
    end

  end
















  class RecursiveGenerator
    
    def self.generate(dirName, pattern, generatorArray)
      taskCollection = Array.new
      recursiveGenerate(dirName, pattern, generatorArray, taskCollection)
      return taskCollection
    end

    def self.recursiveGenerate(dirName, pattern, generatorArray, taskCollection)
      Dir.chdir(dirName)
      # first recurse into sub directories
      Dir['*/'].each { |subDir| recursiveGenerate(dirName + subDir, pattern, generatorArray, taskCollection) }

      # then catch all files matching the pattern and add a compile task for each one
      matchFiles = Dir[pattern]
      matchFiles.each do |fileName|
        generatorArray.each do |generator|
          task = generator.generate(dirName, fileName)
          if task != nil then
            taskCollection.push(task)
          end
        end
      end
      Dir.chdir("..")
    end
  end
  




  
  class CompileTaskGenerator

    def initialize(build, config)
      @build = build
      @config = config
    end
    
    def generate(dirName, fileName)
      fullFileName = (dirName + fileName).strip
      compileTaskName = CompileTask.makeName(fullFileName)
      if not @build.hasTask?(compileTaskName)
        localTask = CompileTask.new(fullFileName, @build, @config)
        @build.addTask(compileTaskName, localTask)
      end
      return @build.getTask(compileTaskName)
    end
    
  end


  

  class RecursiveCompileTaskGenerator
    # expects an absolute path in dirName, where to find the files matching the pattern and adds all CompileTask objects to
    # the taskHash of build and returns the list of CompileTasks made
    def self.generate(dirName, pattern, build, config)
      generatorArray = [CompileTaskGenerator.new(build, config)]
      return RecursiveGenerator.generate(dirName, pattern, generatorArray)
    end
  end



  
  class ProgramGenerator
    def self.generate(dirName, pattern, build, progName, config)
      compileTasksArray = RecursiveCompileTaskGenerator.generate(dirName, pattern, build, config)
      Makr.log.debug("compileTasksArray.size: " + compileTasksArray.size.to_s)
      progName.strip!
      programTaskName = ProgramTask.makeName(progName)
      if not build.hasTask?(programTaskName)
        build.addTask(programTaskName, ProgramTask.new(progName, build))
      end
      programTask = build.getTask(programTaskName)
      compileTasksArray.each do |compileTask|
        programTask.addDependency(compileTask)
      end
      programTask
    end
  end




  class UpdateTraverser
    
    class Updater
      
      def initialize(task, threadPool)
        @task = task
        @threadPool = threadPool
      end
      
      # we need to go up the tree with the traversal even in case dependency did not update
      # just to increase the dependenciesUpdatedCount in each marked node so that in case
      # of the update of a single child, the node will surely be updated! An intermediate node
      # might not be updated, as the argument callUpdate is false, but the algorithm logic
      # still needs to handle dependant tasks for the above reason.
      def run(callUpdate)
        if SignalHandler.setSigUsr1 then  # if the user sent a signal to this process, then we just exit all
          return                          # runnables that start without spawning new ones (which happens below)
        end
        @task.mutex.synchronize do
          if not @task.updateMark
            raise "Unexpectedly starting on a task that needs no update!"
          end
          retVal = false
          if(callUpdate)
            retVal = @task.update()
          end
          @task.updateMark = false
          @task.dependantTasks.each do |dependantTask|
            dependantTask.mutex.synchronize do
              if dependantTask.updateMark # only work on dependant tasks that want to be updated eventually
                dependantTask.dependencyWasUpdated ||= retVal
                # if we are the last thread to reach the dependant task, we will run the next thread
                # on it. The dependant task needs to be updated if at least a single dependency task
                # was update (which may not be the task of this thread)
                dependantTask.dependenciesUpdatedCount = dependantTask.dependenciesUpdatedCount + 1
                if(dependantTask.dependenciesUpdatedCount == dependantTask.dependencies.size)
                  updater = Updater.new(dependantTask, @threadPool)
                  @threadPool.execute {updater.run(dependantTask.dependencyWasUpdated)}
                end
              end
            end
          end
        end  
      end
      
    end # end of nested class Updater

    
    def initialize(nrOfThreadsInPool)
      @threadPool = ThreadPool.new(nrOfThreadsInPool)
    end
    

    # root must be a task. The traversal works as follows: we walk down the DAG until we reach
    # tasks with no dependencies. Upon this walk we mark all tasks we visit. Then, from the
    # independent tasks, we walk up again and run an Updater thread on each marked node. The number
    # of threads is limited by a thread pool.
    #
    # TODO: We expect the DAG to have no cycles here. Should we check?
    def traverse(root) 
      collectedTasksWithNoDeps = Array.new
      recursiveMarkAndCollectTasksWithNoDeps(root, collectedTasksWithNoDeps)
      collectedTasksWithNoDeps.uniq!
      Makr.log.debug("collectedTasksWithNoDeps.size: " + collectedTasksWithNoDeps.size.to_s)
      collectedTasksWithNoDeps.each do |noDepsTask|
        updater = Updater.new(noDepsTask, @threadPool)
        @threadPool.execute {updater.run(true)}
      end
      @threadPool.join()
    end

    
    def recursiveMarkAndCollectTasksWithNoDeps(task, collectedTasksWithNoDeps)
      # prepare the task variables upon descend
      task.updateMark = true
      task.dependenciesUpdatedCount = 0
      task.dependencyWasUpdated = false

      # then collect, if no further deps or recurse
      if(task.dependencies.empty?)
        collectedTasksWithNoDeps.push(task)
        return
      end
      task.dependencies.each{|dep| recursiveMarkAndCollectTasksWithNoDeps(dep, collectedTasksWithNoDeps)}
    end
    
  end




  # script argument management

  class ScriptArguments

    attr_reader :scriptFile, :arguments

    def initialize(scriptFile, arguments)
      @scriptFile = scriptFile
      @arguments = arguments
    end
  end

  
  class ScriptArgumentsStorage
    @@store = Array.new
    def self.get()
      @@store
    end
  end
  

  def self.pushArgs(scriptArguments)
    ScriptArgumentsStorage.get.push(scriptArguments)
  end

  
  def self.popArgs()
    if (ScriptArgumentsStorage.get.size < 2) then
      Makr.log.fatal "Tried to remove the minimum arguments from stack, exiting!"
      abortBuild()
    end
    ScriptArgumentsStorage.get.pop
  end

  
  def self.getArgs()
    ScriptArgumentsStorage.get.last
  end

  
  # just a convenience function, loads a Makrfile.rb from the given subDir and executes it
  def self.makeSubDir(subDir)
    makrFilePath = subDir + "/Makrfile.rb"
    pushArgs(ScriptArguments.new(makrFilePath, getArgs().arguments))
    Kernel.load(makrFilePath)
    popArgs()
  end

  class SignalHandler
    def self.setSigUsr1()
      @@sigUsr1Called = true
    end
    def self.getSigUsr1()
      if @@sigUsr1Called == nil then
        return false
      else
        @@sigUsr1Called
      end
    end
  end
  
end     # end of module makr




















make config load/store in xml?










####################################################################################################################

# MAIN logic and interface with client code following

####################################################################################################################
Makr.log.level = Logger::DEBUG
Makr.log.formatter = proc { |severity, datetime, progname, msg|
    "[makr] #{severity} #{msg}\n"
}
Makr.log << "\n\nmakr version 2011.06.18\n\n"  # just give short version notice on every startup (Date-encoded)

Signal.trap("USR1")  { Makr::SignalHandler.setSigUsr1 }

# now we load the Makrfile.rb and use Kernel.load on them to execute them as ruby scripts
makrFilePath = Dir.pwd + "/Makrfile.rb"
if File.exist?(makrFilePath) then
  Makr.pushArgs(Makr::ScriptArguments.new(makrFilePath, ARGV))
  Kernel.load(makrFilePath)
else
  Makr.log.error("No Makrfile.rb found!")  
end

