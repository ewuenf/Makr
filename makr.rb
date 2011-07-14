#!/usr/bin/ruby


# This is my own home-brewn ruby-based build tool.
# I hereby name it "makr" and it will read "Makrfiles", uenf!
#
# Documentation is sparse as source is short and a number
# of examples are/willbe provided.



require 'ftools'
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
  # own methods / classes follow


  
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



  
  # Hierarchical configuration management. Asking for a key will walk up
  # in hierarchy, until key is found or a new entry needs to be created in root config.
  # Hierarchy is with single parent. Regarding construction and usage of configs see class Build.
  # Keys could follow naming rules like "my.perfect.config.key"
  class Config

    attr_reader   :name, :parent

    
    def initialize(name, parent = nil) # parent is a config, too
      @name = name
      @parent =  parent
      @hash = Hash.new
    end

    
    def [](key)
      if @hash.has_key?(key) or not @parent then
        # we have the key and return it or we have no parent and return nil (the hash returns nil if it hasnt got the key)
        return @hash[key]
      else # case: hash has not got the key and we have a parent
        # the following will either return a value to the key found in one of the recursive parents or it will
        # return nil, as the key was not found (comparable to a standard hash behaviour)
        return @parent[key]
      end
    end

    
    def []=(key, value)
      # we always assign, regardless of the parent, which may have the same key, as the keys
      # in this class override the parents keys (see also [](key))
      @hash[key] = value
    end


    def output(io)
      io << "  start " << @name << "\n"
      if @parent then
        io << "  parent " << @parent.name << "\n"
      end
      sortedHash = @hash.sort
      sortedHash.each do |entry|
        io << "    \"" << entry[0] << "\"=\"" << entry[1] << "\"\n"
      end
      io << "  end " << @name << "\n\n"
    end

    
    def input(lines, lineIndex, parentName)
      foundStart = false
      lineIndex -=1  # we first decrease lineIndex as there is no fuckin c-style-for-loop in this language-garbage!
      while lineIndex < lines.size() do
        lineIndex +=1
        line = lines[lineIndex]
        # remove whitespace
        line.strip!
        #ignore newlines
        if line.empty? then 
          next
        end
        # at first, we need to have a start marker
        if not foundStart then
          if not line.index("start") then
            Makr.log.error("Config parse error at line nr " + lineCount.to_s)
            return false
          else
            @name = line["start ".length, -2]
            foundStart = true
            next
          end
        end
        # then we check for a parent
        if line.index("parent") == 0 then
          parentName = line["parent ".length, -2]
          next
        end
        # if we find the end marker, we can return true
        if line.index("end") == 0 then
          return true
        end
        splitArr = line.split("\"=\"")
        if splitArr.size < 2 then
          Makr.log.error("Parse error at line nr " + lineIndex.to_s)
          return false
        end
        @hash[splitArr[0]] = splitArr[-1]
      end
      return false # gone through all lines without finding end
    end

  end


  

  # Basic class and concept representing a node in the dependency tree and any type of action that
  # needs to be performed (such as a versioning system update or somefingelse)
  class Task
    
    attr_reader :name, :dependencies, :dependantTasks
    # these are used by the multi-threaded UpdateTraverser
    attr_accessor :mutex, :updateMark, :dependenciesUpdatedCount, :dependencyWasUpdated, :configName

    
    def initialize(name) # name should be unique !
      @name = name
      @dependencies = Array.new
      @dependantTasks = Array.new

      # regarding the meaning of these see class UpdateTraverser
      @mutex = Mutex.new
      @updateMark = false
      @dependenciesUpdatedCount = 0
      @dependencyWasUpdated = false

      @configName = String.new  # got no config so far
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

    
    # Every subclass should provide an "update()" function, that returns wether the target of the task is updated/changed.
    # The task graph should be unchanged during update. Use functions preUpdate() or postUpdate() for this purpose.
    def update() 
      false
    end

    # postUpdate() is called after all tasks have been "update()"d. Task instances need to register for the
    # postUpdate()-call during the update()-call using Build::registerPostUpdate(task). While update() is called in
    # parallel on the task graph and should not modify the graph, This function is called on all registered tasks in a
    # single thread, so that no issues with multi-threading can occur. As this obviously is a bottleneck, the function
    # should only be used, if necessary. This behaviour might change in future revisions of this tool, as the author or
    # someone else might get better concepts out of his brain.
    def postUpdate()
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

  end




  # Represents a compiled source that has dependencies to included files (and any deps that a user may specify).
  # The input files are dependencies on FileTasks including the source itself. Another dependency exists on the
  # target object file, so that the task rebuilds, if that file was deleted or modified otherwise.
  class CompileTask < Task
    
    def makeCompilerCallString()
      config = @build.getConfig(@configName)
      config["compiler"] + " " + config["compiler.cFlags"] + " " + \
        config["compiler.defines"] + " " + config["compiler.includePaths"]
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
      getDepsStringArrayFromCompiler()
      buildDependencies() 

      Makr.log.debug("made CompileTask with @name=\"" + @name + "\" and output file " + @objectFileName)
    end

    def getDepsStringArrayFromCompiler()
      # we use the compiler for now, but maybe fastdep is worth a look / an adaption
      # we are excluding system headers for now (option "-MM"), but that may not bring performance, then use option "-M"
      dependOption = " -M "
      if @@checkOnlyUserHeaders
        dependOption = " -MM "
      end
      depCommand = makeCompilerCallString() + dependOption + @fileName
      Makr.log.info("Executing compiler to check for dependencies in CompileTask: \"" + @fileName + "\"\n\t" + depCommand)
      compilerPipe = IO.popen(depCommand)  # in ruby >= 1.9.2 we could use Open3.capture2(...) for this purpose
      @dependencyLines = compilerPipe.readlines
      if @dependencyLines.empty?
        Makr.log.error("error in CompileTask: \"" + @fileName + "\" making dependencies failed, check file!")
      end
    end
    
    def buildDependencies()
      clearDependencies()
      dependencyFiles = Array.new
      @dependencyLines.each do |depLine|
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
      # construct compiler command and execute it
      compileCommand = makeCompilerCallString() + " -c " + @fileName + " -o " + @objectFileName
      Makr.log.info("Executing compiler in CompileTask: \"" + @fileName + "\"\n\t" + compileCommand)
      successful = system(compileCommand)
      if not successful
        Makr.log.fatal("compile error, exiting build process\n\n\n")
        abortBuild()
      end
      @compileTarget.update() # we call this to update file information on the compiled target
      # we always want this if any dependency changed, as this could mean changed dependencies due to new includes etc.
      getDepsStringArrayFromCompiler()
      @build.registerPostUpdate(self)
      return true # right now, we are always true (we could check for target equivalence or something else)
    end

    def postUpdate()
      buildDependencies()  # assuming we have called the compiler already in update giving us the deps string
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

    
    # make a unique name for ProgramTasks out of the programName which is to be compiled
    def self.makeName(programName)
       "ProgramTask__" + programName
    end


    def makeLinkerCallString()
      config = @build.getConfig(@configName)
      config["linker"] + " " + config["linker.lFlags"] + " " + config["linker.libPaths"] + " " + config["linker.libs"]
    end

    
    def initialize(programName, build, config)
      @programName = programName
      super(ProgramTask.makeName(@programName))
      @build = build
      @config = config

      if not @build.hasTask?(@programName) then
        @compileTarget = FileTask.new(@programName, false)
        @build.addTask(@programName, @compileTarget)
      else
        @compileTarget = @build.getTask(@programName)
      end
      addDependency(@compileTarget)

      Makr.log.debug("made ProgramTask with @name=\"" + @name + "\"")
    end
    

    def update()
      # build compiler command and execute it
      linkCommand = makeLinkerCallString() + " -o " + @programName
      @dependencies.each do |dep|
        if dep == @compileTarget then
          next
        end
        linkCommand += " " + dep.objectFileName
      end
      Makr.log.info("Building programTask \"" + @name + "\"\n\t" + linkCommand)
      system(linkCommand)  # TODO we dont check for return here. maybe we should?
      @compileTarget.update() # we call this to update file information on the compiled target
      return true # this is always updated
    end

    
    def cleanupBeforeDeletion()
      system("rm -f " + @programName)
    end
    
  end

  


  class Build

    attr_reader   :buildPath, :configs
    attr_accessor :postUpdates


    # build path should be absolute and is read-only once set in this "ctor"
    def initialize(buildPath) 
      @buildPath     = buildPath
      @buildPathMakrDir = @buildPath + "/.makr"
      @buildPath.freeze # set vars readonly
      @buildPathMakrDir.freeze
      if not File.directory?(@buildPathMakrDir)
        Dir.mkdir(@buildPathMakrDir)
      end

      @postUpdates = Array.new

      # task hash
      @taskHash      = Hash.new            # maps task names to tasks (names are for example full path file names)
      @taskHashCache = Hash.new            # a cache for the task hash that is loaded below
      @taskHashCacheFile  = @buildPathMakrDir + "/taskHashCache.ruby_marshal_dump"  # where the task hash cache is stored to
      loadTaskHashCache()

      # configs
      @configs = Hash.new
      @configsFile  = @buildPathMakrDir + "/config.txt"
      loadConfigs()  # loads configs from build dir and assign em to tasks
      if @configs.empty? do
        @configs["default"] = Config.new("default")
        @configs["default"]["compiler"] = "g++"
        @configs["default"]["linker"] = "g++"
      end
    end


    def registerPostUpdate(task).
      @postUpdates.push(task)
    end

    def doPostUpdates()
      @postUpdates.each do |task|
        task.postUpdate()
      end
    end
    

    def hasTask?(taskName)
      return (@taskHash.has_key?(taskName) or @taskHashCache.has_key?(taskName))
    end


    def getTask(taskName)
      if @taskHash.has_key?(taskName) then
        return @taskHash[taskName]
      elsif @taskHashCache.has_key?(taskName) then
        addTaskPrivate(taskName, @taskHashCache[taskName])  # we make a copy upon request
        return @taskHash[taskName]
      else
        nil  # return nil, if not found (TODO raise an exception here?)
      end
    end


    def addTask(taskName, task)
        addTaskPrivate(taskName, task)
    end

    
    def removeTask(taskName)
      if @taskHash.has_key?(taskName) then # we dont bother about cache here, as cache is overwritten on save to disk
        @taskHash.delete(taskName)
      else
        raise "[makr] removal of non-existant task requested!"
      end
    end

    def save()
      dumpTaskHash()
      dumpConfigs()
    end

    def hasConfig?(name)
      return @configs.has_key?(name)
    end
    
    def getConfig(name)
      @configs[name]
    end

    def makeNewConfig(name, parentName = nil)
      if hasConfig?(name) do
        raise "[makr] config with name " + name + " already existing!"
      end
      @configs[name] = Config.new(name)
      if parentName do
        if not hasConfig?(parentName) do
          raise "[makr] config parent with name " + parentName + " not existing!"
        end
        @configs[name].parent = @configs[parentName]
      end
    end

    def deleteConfig(name)
      if not @configs.has_key?(name) then # we dont bother about cache here, as cache is overwritten on save to disk
        raise "[makr] removal of non-existant config requested!"
      else
        configsToDeleteArray = Array.new
        currentConfig = @configs[name]
      end
    end
    
  private

    def addTaskPrivate(taskName, task)
      if @taskHash.has_key? taskName then
        Makr.log.warn("Build::addTaskPrivate, taskName exists already!: " + taskName)
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

    
    def dumpTaskHash()
      mutex.synchronize do
        # then dump the hash (and not the cache!, this way we get overridden cache next time)
        File.open(@taskHashCacheFile, "wb") do |dumpFile|
          Marshal.dump(@taskHash, dumpFile)
        end
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


    def loadConfigs()  # loads configs from build dir
      if File.file?(@configsFile)
        Makr.log.info("found config file, now restoring\n\n")
        lines = IO.readlines(@configsFile)
        lineIndex = 0
        while lineIndex < lines.size() do
          config = Config.new("")
          parentName = nil
          if not config.input(lines, lineIndex, parentName) do
            Makr.log.error("parse error in config file before lineIndex: " + lineIndex.to_s)
            return
          else
            if parentName do
              if not @configs.has_key?(parentName) do
                Makr.log.error("parent name unknown in config file before lineIndex: " + lineIndex.to_s)
                return
              end
              config.parent = @configs[parentName]
              @configs[name] = config
            end
          end
        end
      else
        Makr.log.warning("could not find or open config file, config needs to be provided!\n\n")
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



  
end     # end of module makr ######################################################################################






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

