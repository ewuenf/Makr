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

    attr_reader   :name, :parent, :childs

    
    def initialize(name, parent = nil) # parent is a config, too
      @name = name
      setParent(parent)
      @hash = Hash.new
      @childs = Array.new
    end


    def setParent(parent)
      unparent()
      @parent =  parent
      @parent.addChild(self) if @parent
    end

    
    def unparent() # kind of dtor
      if @parent then
        @parent.removeChild(self)
        @parent = nil
      end
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

    
    # returns (Boolean,Integer,String) with the meaning:
    # (parsing went well, last line visited, parent name)
    def input(lines, lineIndex)
      foundStart = false
      parentName = nil
      for i in (lineIndex..(lines.size() - 1)) do
        line = lines[i]
        # remove whitespace
        line.strip!
        #ignore newlines
        next if line.empty?
        # at first, we need to have a start marker
        if not foundStart then
          if not line.index("start") then
            Makr.log.error("Config parse error at line nr " + i.to_s)
            return false, i, parentName
          else
            @name = line[("start ".length)..-1]
            foundStart = true
            next
          end
        end
        # then we check for a parent
        if line.index("parent") == 0 then
          parentName = line["parent ".length..-1]
          next
        end
        # if we find the end marker, we can return true
        if line.index("end") == 0 then
          return true, i, parentName
        end
        splitArr = line.split("\"=\"")
        if splitArr.size < 2 then
          Makr.log.error("Parse error at line nr " + i.to_s)
          return false, i, parentName
        end
        @hash[(splitArr[0])[1..-1]] = (splitArr[-1])[0..-2]
      end
      # gone through all lines, so we return, if start was found anyway and we expected end somewhere
      return (not foundStart), i, parentName
    end

    
  protected

  
    def addChild(config)
      @childs.push(config)
    end

    
    def removeChild(config)
      @childs.delete(config)
    end

    
  end



  



  
  

  # Basic class and concept representing a node in the dependency tree and any type of action that
  # needs to be performed (such as a versioning system update or somefingelse). A possible configuration
  # of the task is only referred to by name as I did not want linked data structures, that would be
  # saved all together upon marshalling in class build. Config class is different.
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
    # The task graph itself should be unchanged during update. Use function postUpdate() for this purpose.
    def update() 
      false
    end

    
    # The method postUpdate() is called after all tasks have been "update()"d. Task instances need to register for the
    # postUpdate()-call during the update()-call using "Build::registerPostUpdate(self)". While update() is called in
    # parallel on the task graph and should not modify the graph, this function is called on all registered tasks in a
    # single thread, so that no issues with multi-threading can occur. As this obviously is a bottleneck, the function
    # should only be used if it is absolutely necessary to modify the task structure upon updating procedure.
    # This behaviour might change in future revisions of this tool, as the author or someone else might get better
    # concepts out of his brain.
    def postUpdate()
    end

    
    # can be impletemented by subclasses indicating that this task is no longer valid due to a circumstance such as
    # a missing file
    def mustBeDeleted?()
      false
    end

    
    def printDependencies(prefix)
      Makr.log.info(prefix + @name + " deps size: " + @dependencies.size.to_s)
      @dependencies.each do |dep|
        dep.printDependencies(prefix + "  ")
      end
    end
    

    def cleanupBeforeDeletion()  # interface mainly for tasks generating targets (removing these)
    end

    
  end





  



  

  class FileTask < Task

    # this variable states, if file hashes should be used to identify changed files (which can be a costly operation)
    @@useFileHash = false
    def FileTask.useFileHash
      @@useFileHash
    end
    def FileTask.useFileHash=(arg)
      @@useFileHash = arg
    end


    attr_reader :fileName, :time, :size, :fileHash, :missingFileIsError # absolute path for fileName expected!

    # the boolean argument missingFileIsError can be used to indicate, if an update is necessary, if file is missing 
    # (which is the "false" case) or if it is an error and the build should abort
    def initialize(fileName, missingFileIsError = true)
      @fileName = fileName
      Makr.log.debug("made file task with @fileName=\"" + @fileName + "\"")
      super(@fileName)
      # all file attribs stay uninitialized, so that first call to update returns true
      @time = @size = @fileHash = String.new
      @missingFileIsError = missingFileIsError
    end

    
    def mustBeDeleted?()
      if (not File.file?(@fileName)) and (@missingFileIsError) then
          Makr.log.info("mustBeDeleted?() is true for missing file: " + @fileName)
          return true
      end
      false
    end

    
    def update()
      if (not File.file?(@fileName))
        if(@missingFileIsError)
          Makr.log.fatal("file " + @fileName + "  is unexpectedly missing!\n\n")
          Makr.abortBuild
        end
        Makr.log.info("FileTask " + @fileName + " is missing, so update() is true.")
        return true
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
      if @@useFileHash then
        curHash = MD5.new(open(@fileName, 'rb').read).hexdigest
        if(@fileHash != curHash)
          @fileHash = curHash
          retValue = true
        end
      end
      if retValue then
        Makr.log.info("file " + fileName + " has changed")
      end
      return retValue
    end

    
  end





  


  

  # This class represents the dependency on changed strings in a Config, it is used for example in CompileTask
  class ConfigTask < Task

    def initalize(name)
      super
      @storedConfigString = String.new
    end
    
    def update()
      if not dependantTasks.first then
        raise "ConfigTask \"" + name + "\" does not have a dependant task, but needs one!"
      end
      currentConfigString = dependantTasks.first.getConfigString()
      retVal = (@storedConfigString != currentConfigString)
      @storedConfigString = currentConfigString
      retVal
    end
    
  end








  
  

  # Represents a compiled source that has dependencies to included files (and any deps that a user may specify).
  # The input files are dependencies on FileTasks including the source itself. Another dependency exists on the
  # target object file, so that the task rebuilds, if that file was deleted or modified otherwise. Also the
  # task has a dependency on the Config object that contains the compiler options etc. so that a change in these
  # also triggers recompilation (see ConfigTask).
  class CompileTask < Task

    
    def makeCompilerCallString()
      Makr.log.debug("config name is: \"" + @configName + "\"")
      config = @build.getConfig(@configName)
      raise "need compiler at least!" if (not config["compiler"])
      
      callString = config["compiler"] + " "
      if config["compiler.cFlags"] then
        callString += config["compiler.cFlags"] + " "
      end
      if config["compiler.defines"] then
        callString += config["compiler.defines"] + " "
      end
      if config["compiler.includePaths"] then
        callString += config["compiler.includePaths"] + " "
      end
      if config["compiler.otherOptions"] then
        callString += config["compiler.otherOptions"] + " "
      end
      return callString
    end

    alias :getConfigString :makeCompilerCallString

    
    # this variable influences dependency checking by the compiler ("-M" or "-MM" option)
    @@checkOnlyUserHeaders = false
    def CompileTask.checkOnlyUserHeaders
      @@checkOnlyUserHeaders
    end
    def CompileTask.checkOnlyUserHeaders=(arg)
      @@checkOnlyUserHeaders = arg
    end

    
    # make a unique name for CompileTasks out of the fileName which is to be compiled
    def CompileTask.makeName(fileName)
      "CompileTask__" + fileName
    end


    # the path of the input and output file of the compilation
    attr_reader :fileName, :objectFileName

    
    # build contains the global configuration, see Build.globalConfig and class Config
    def initialize(fileName, build, configName)
      @fileName = fileName
      @build = build
      @configName = configName

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
      # now add another dependency task on the config
      @configTaskName = "ConfigTask__" + @fileName
      if not @build.hasTask?(@configTaskName) then
        @configTask = ConfigTask.new(@configTaskName)
        @build.addTask(@configTaskName, @configTask)
      else
        @configTask = @build.getTask(@configTaskName)
      end

      # the following first deletes all deps and then constructs them including the @compileTarget and the @configTask
      getDepsStringArrayFromCompiler()
      buildDependencies() 

      Makr.log.debug("made CompileTask with @name=\"" + @name + "\" and output file " + @objectFileName)
    end

    
    def getDepsStringArrayFromCompiler()
      # we use the compiler for now, but maybe fastdep is worth a look / an adaption
      # system headers are excluded using compiler option "-MM", else "-M"
      depCommand = makeCompilerCallString() + ((@@checkOnlyUserHeaders)?" -MM ":" -M ") + @fileName
      Makr.log.info("Executing compiler to check for dependencies in CompileTask: \"" + @fileName + "\"\n\t" + depCommand)
      compilerPipe = IO.popen(depCommand)  # in ruby >= 1.9.2 we could use Open3.capture2(...) for this purpose
      @dependencyLines = compilerPipe.readlines
      if @dependencyLines.empty?
        Makr.log.error( "error in CompileTask: \"" + @fileName + \
                        "\" making dependencies failed, check file for syntax errors!")
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
          dependencyFiles.concat(splitArr[1].split(" "))
        else
          dependencyFiles.concat(depLine.split(" "))
        end
      end
      dependencyFiles.each do |depFile|
        depFile.strip!
        next if depFile.empty?
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
      # we need to add the config task again!
      addDependency(@configTask)
    end

    
    def update()
      # we do not modify task structure on update and defer this to the postUpdate call like good little children
      @build.registerPostUpdate(self)
      # we first execute the compiler to deliver an update on the dependent includes. We could do this
      # in postUpdate, too, but we assume this to be faster, as the files should be in OS cache afterwards and
      # compilation (the next step) should be faster
      getDepsStringArrayFromCompiler()
      # construct compiler command and execute it
      compileCommand = makeCompilerCallString() + " -c " + @fileName + " -o " + @objectFileName
      Makr.log.info("Executing compiler in CompileTask: \"" + @fileName + "\"\n\t" + compileCommand)
      successful = system(compileCommand)
      if not successful then
        Makr.log.fatal("compile error, exiting build process\n\n\n")
        abortBuild()
      end
      @compileTarget.update() # we call this to update file information on the compiled target
      return true # right now, we are always true (we could check for target equivalence or something else
                  # and then return false in case the target didnt change (based on file hash))
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
      puts "config name is: \"" + @configName + "\""
      config = @build.getConfig(@configName)
      callString = String.new
      if not config["linker"] then
        raise "need linker at least!"
      else
        callString +=  config["linker"] + " "
      end
      if config["linker.lFlags"] then
        callString += config["linker.lFlags"] + " "
      end
      if config["linker.libPaths"] then
        callString += config["linker.libPaths"] + " "
      end
      if config["linker.libs"] then
        callString += config["linker.libs"] + " "
      end
      if config["linker.otherOptions"] then
        callString += config["linker.otherOptions"] + " "
      end
      callString
    end
    alias :getConfigString :makeLinkerCallString

    
    def initialize(programName, build, configName)
      @programName = programName
      super(ProgramTask.makeName(@programName))
      @build = build
      @configName = configName

      if not @build.hasTask?(@programName) then
        @compileTarget = FileTask.new(@programName, false)
        @build.addTask(@programName, @compileTarget)
      else
        @compileTarget = @build.getTask(@programName)
      end
      addDependency(@compileTarget)
      # now add another dependency task on the config
      @configTaskName = "ConfigTask__" + @programName
      if not @build.hasTask?(@configTaskName) then
        @configTask = ConfigTask.new(@configTaskName)
        @build.addTask(@configTaskName, @configTask)
      else
        @configTask = @build.getTask(@configTaskName)
      end
      addDependency(@configTask)

      Makr.log.debug("made ProgramTask with @name=\"" + @name + "\"")
    end
    

    def update()
      # build compiler command and execute it
      linkCommand = makeLinkerCallString() + " -o " + @programName
      @dependencies.each do |dep|
        if dep.instance_variable_defined?("@objectFileName") then
          linkCommand += " " + dep.objectFileName
        end
      end
      Makr.log.info("Building programTask \"" + @name + "\"\n\t" + linkCommand)
      successful = system(linkCommand)
      if not successful then
        Makr.log.fatal("linker error, exiting build process\n\n\n")
        abortBuild()
      end
      @compileTarget.update() # we call this to update file information on the compiled target
      return true # we could check here for target change like proposed in CompileTask.update
    end

    
    def cleanupBeforeDeletion()
      system("rm -f " + @programName)
    end
    
  end





  
  


  class Build

    attr_reader   :buildPath, :configs
    #attr_accessor :postUpdates


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
    end


    def registerPostUpdate(task)
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


    def clearConfigs()
      @configs.clear()
    end

    
    def hasConfig?(name)
      return @configs.has_key?(name)
    end

    
    def getConfig(name)
      if not hasConfig?(name) then
        raise "no such config: " + name
      end
      @configs[name]
    end


    def makeNewConfig(name, parentName = nil)
      if hasConfig?(name) then
        return getConfig(name)
      end
      parent = nil
      if parentName then
        if not hasConfig?(parentName) then
          raise "[makr] requested config parent with name " + parentName + " not existing!"
        end
        parent = @configs[parentName]
      end
      @configs[name] = Config.new(name, parent)
    end


    def makeNewConfigForTask(name, task)
      if task.configName == name then # already have this config
        return getConfig(name)
      end
      newConf = makeNewConfig(name, task.configName)
      task.configName = name
      return newConf
    end


    def save(cleanupConfigs = true)
      dumpTaskHash()
      dumpConfigs(cleanupConfigs)
    end

    
  protected

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
      # dump the hash (and not the cache!, this way we get cleaned cache next time)
      File.open(@taskHashCacheFile, "wb") do |dumpFile|
        Marshal.dump(@taskHash, dumpFile)
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
          if (not (lines[lineIndex])) or (lines[lineIndex] == "") then
            lineIndex += 1
            next
          end
          config = Config.new("")
          parsingGood, lineIndex, parentName = config.input(lines, lineIndex)
          if parsingGood then
            lineIndex += 1 # go on to next line
            if parentName then
              if not @configs.has_key?(parentName) then
                Makr.log.error("parent name unknown in config file before lineIndex: " + lineIndex.to_s)
                return
              end
              config.setParent(@configs[parentName])
            end
            if config.name != "" then  # we only add configs with a name!
              @configs[config.name] = config
            end
          else
            Makr.log.error("parse error in config file before lineIndex: " + lineIndex.to_s)
            return
          end
        end
      else
        Makr.log.warn("could not find or open config file, config needs to be provided!\n\n")
      end
    end

    
    def cleanConfigs()
      saveHash = Hash.new
      @taskHash.each do |key, value|
        if value.configName and not (saveHash.has_key?(value.configName)) then # save each config once
          saveHash[value.configName] = @configs[value.configName]
          @configs.delete(value.configName)
        end
      end
      # now only Config instance remain in @configs, that have no reference in tasks.
      # we could delete them all, but some are intermediate nodes in the Config graph
      # thus we only delete those, that have no childs recursively
      deletedSomething = true
      while deletedSomething
        deletedSomething = false
        @configs.delete_if do |name, config|
          if config.childs.empty? then
            config.unparent()
            deletedSomething = true
          else
            false
          end
        end
      end
      saveHash.each do |key, value|
        @configs[key] = value
      end
    end

    
    def dumpConfigs(cleanupConfigs)
      if cleanupConfigs then
        cleanConfigs()
      end
      File.open(@configsFile, "w") do |dumpFile|
        @configs.each do |key, value|
          puts "key: " + key + " value: " + value.to_s
          value.output(dumpFile)
        end
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
      # first recurse into sub directories
      Dir[dirName + '*/'].each { |subDir| recursiveGenerate(subDir, pattern, generatorArray, taskCollection) }

      # then catch all files matching the pattern and add a compile task for each one
      matchFiles = Dir[dirName + pattern]
      matchFiles.each do |fileName|
        generatorArray.each do |generator|
          task = generator.generate(fileName)
          if task != nil then
            taskCollection.push(task)
          end
        end
      end
    end
  end
  





  

  

  
  class CompileTaskGenerator

    def initialize(build, configName)
      @build = build
      @configName = configName
    end
    
    def generate(fileName)
      fileName.strip!
      compileTaskName = CompileTask.makeName(fileName)
      if not @build.hasTask?(compileTaskName) then
        localTask = CompileTask.new(fileName, @build, @configName)
        @build.addTask(compileTaskName, localTask)
      end
      return @build.getTask(compileTaskName)
    end
    
  end





  

  

  class RecursiveCompileTaskGenerator
    # expects an absolute path in dirName, where to find the files matching the pattern and adds all CompileTask objects to
    # the taskHash of build and returns the list of CompileTasks made
    def RecursiveCompileTaskGenerator.generate(dirName, pattern, build, configName)
      generatorArray = [CompileTaskGenerator.new(build, configName)]
      return RecursiveGenerator.generate(dirName, pattern, generatorArray)
    end
  end





  


  
  class ProgramGenerator
    def ProgramGenerator.generate(dirName, pattern, build, progName, taskConfigName)
      compileTasksArray = RecursiveCompileTaskGenerator.generate(dirName, pattern, build, taskConfigName)
      Makr.log.debug("compileTasksArray.size: " + compileTasksArray.size.to_s)
      progName.strip!
      programTaskName = ProgramTask.makeName(progName)
      if not build.hasTask?(programTaskName) then
        build.addTask(programTaskName, ProgramTask.new(progName, build, taskConfigName))
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
        if SignalHandler.sigUsr1Called then  # if the user sent a signal to this process, then we just exit all
          puts "returning on signal usr1"
          return                          # runnables that start without spawning new ones (which happens below)
        end
        @task.mutex.synchronize do
          if not @task.updateMark then
            raise "Unexpectedly starting on a task that needs no update!"
          end
          retVal = false
          if callUpdate then
            retVal = @task.update()
          end
          @task.updateMark = false
          @task.dependantTasks.each do |dependantTask|
            dependantTask.mutex.synchronize do
              if dependantTask.updateMark then # only work on dependant tasks that want to be updated eventually
                dependantTask.dependencyWasUpdated ||= retVal
                # if we are the last thread to reach the dependant task, we will run the next thread
                # on it. The dependant task needs to be updated if at least a single dependency task
                # was update (which may not be the task of this thread)
                dependantTask.dependenciesUpdatedCount = dependantTask.dependenciesUpdatedCount + 1
                if (dependantTask.dependenciesUpdatedCount == dependantTask.dependencies.size) then
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
      if task.dependencies.empty? then
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
    def ScriptArgumentsStorage.get()
      @@store
    end
  end
  

  def Makr.pushArgs(scriptArguments)
    ScriptArgumentsStorage.get.push(scriptArguments)
  end

  
  def Makr.popArgs()
    if (ScriptArgumentsStorage.get.size < 2) then
      Makr.log.fatal "Tried to remove the minimum arguments from stack, exiting!"
      abortBuild()
    end
    ScriptArgumentsStorage.get.pop
  end

  
  def Makr.getArgs()
    ScriptArgumentsStorage.get.last
  end

  
  # just a convenience function, loads a Makrfile.rb from the given subDir and executes it
  def Makr.makeSubDir(subDir)
    makrFilePath = subDir + "/Makrfile.rb"
    pushArgs(ScriptArguments.new(makrFilePath, getArgs().arguments))
    Kernel.load(makrFilePath)
    popArgs()
  end








  
  
  class SignalHandler
    @@sigUsr1Called = false
    def SignalHandler.sigUsr1Called
      @@sigUsr1Called
    end
    def SignalHandler.sigUsr1Called=(arg)
      @@sigUsr1Called = arg
    end
  end



  


  
end     # end of module makr ######################################################################################













####################################################################################################################

# MAIN logic and interface with client code following

####################################################################################################################
Makr.log.level = Logger::DEBUG
Makr.log.formatter = proc { |severity, datetime, progname, msg|
    "[makr #{severity} #{datetime}]    #{msg}\n"
}
Makr.log << "\n\nmakr version 2011.07.31\n\n"  # just give short version notice on every startup (Date-encoded)

Signal.trap("USR1")  { Makr::SignalHandler.setSigUsr1 }

# now we load the Makrfile.rb and use Kernel.load on them to execute them as ruby scripts
makrFilePath = "./Makrfile.rb"
if File.exist?(makrFilePath) then
  Makr.pushArgs(Makr::ScriptArguments.new(makrFilePath, ARGV))
  Kernel.load(makrFilePath)
else
  Makr.log.error("No Makrfile.rb found!")  
end

