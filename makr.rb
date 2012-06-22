#!/usr/bin/ruby


# This is my own home-brewn ruby-based build tool.
# I hereby name it "makr" and it will read "Makrfiles", uenf!
#
# Documentation is sparse as source is short and readable and a number
# of examples are/willbe provided.
#
#
# Some remarks: In general, we want relative paths, so that development dirs can be moved without whoes. 
#               The user may still prefer absolute paths (and use them), but the script tries to make no assumptions.
#               We also make no assumptions on the command lines arguments given, the user is free to parse
#               his own parameter set (using OptionParser from the stdlib for example).
#               The only thing this script does is loading the Makrfile.rb and providing
#               the command line argument in the ScriptArguments stack. The name "Makrfile.rb" is hardcoded, but
#               the user may be free to use this file to load some other file and execute it depending on the
#               parameters given on the command line.
#               During update, the task graph is not modified (only a convention, not enforced), so that programming
#               the multithreaded update is much more simplified.


require 'fileutils'
require 'find'
require 'thread'
require 'digest/md5'
require 'logger'
require 'stringio'





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
    attr_reader :nrOfThreads

    # Initialize with nrOfThreads threads to run (if count is not given, all processors of the system will be used)
    def initialize(nrOfThreads = nil, queue_limit = 0)
      @mutex = Mutex.new
      @executors = []
      @queue = []
      @queue_limit = queue_limit
      if nrOfThreads then
        @nrOfThreads = nrOfThreads
      else
        @nrOfThreads = `grep -c processor /proc/cpuinfo`.to_i  # works only on linux (and maybe most unixes)
      end
      @nrOfThreads.times { @executors << Executor.new(@queue, @mutex) }
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
      @nrOfThreads
    end

    # Kills all threads
    def close
      @executors.each {|e| e.close }
    end

    # Sleeps and blocks until the task queue is finished executing
    def join
      while (not (@queue.empty? and @executors.all?{|e| !e.active}))
        sleep 0.01
      end
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
  def Makr.log()
    @log ||= Logger.new(STDOUT)
  end




  # central aborting method (cooperative abort, see UpdateTraverser::Updater)
  def Makr.abortBuild()
    Makr.log.fatal("Aborting build process.")
    UpdateTraverser.abortBuild = true
  end




  # a helper function to clean a pathName fed into the function coming out with no slashes at the end
  def Makr.cleanPathName(pathName)
    Makr.log.warn("Trying to clean empty pathName!") if (not pathName or pathName.empty?)
    # first remove slashes at the end
    pathName = pathName.gsub(/\/+$/, '') # returns nil, if no substitution is performed
    # then, if we have a relative path, let it begin with ./
    if pathName.index("/") != 0 then # have a relative path
      hasRelativePathBegin = pathName.index("./") # is nil if not found, index otherwise!
      if (not hasRelativePathBegin) or (hasRelativePathBegin > 0) then
        pathName = "./" + pathName 
      end
    end
    return pathName
  end





  # Hierarchical configuration management (Config instances have a parent) resembling a hash. Asking for a key will walk up
  # in hierarchy, until key is found or a new entry needs to be created in root config.
  # Hierarchy is with single parent. Regarding construction and usage of configs see class Build or examples.
  # Keys could follow dot-seperated naming rules like "my.perfect.config.key". The hash is saved in a human-readable
  # form in a file in the build directory (could even be edited by hand).
  class Config

    # doubly linked tree (parent and childs), childs used for cleanup (see class Build)
    attr_reader   :name, :parent, :childs


    def initialize(name, parent = nil) # parent is a config, too
      @name = name
      setParent(parent)
      @hash = Hash.new
      @childs = Array.new
    end


    # constructs and return a new Config with this Config as parent
    def makeChild(newName)
      Config.new(newName, self)
    end
    alias :derive :makeChild


    def setParent(parent)
      unparent()
      @parent =  parent
      @parent.addChild(self) if @parent
    end


    def unparent() # kind of dtor
      @parent.removeChild(self) if @parent
      @parent = nil
    end


    def clear()
      @hash.clear()
    end


    # copies all keys of the immediate parent to this config or only the key given
    def copyParent(key = nil)
      return if not @parent
      if key then
        @hash[key] ||= @parent[key]
      else
        # collect the complete hash
        # duplicate keyz are resolved in favor of the argument of the merge!-call, which is what we want here
        # (this way we overwrite with the parents keys)
        @hash.merge!(@parent.hash)
      end
    end


    # adds value to the keys value if it is not already included (useful for adding compiler options etc)
    def addUnique(key, value)
      curVal = @hash[key]
      if curVal then
        curVal += value if not curVal.include?(value)
        @hash[key] = curVal
      else
        @hash[key] = value
      end
    end


    # convenience mix function of copyParent and addUnique
    def copyAddUnique(key, value)
      copyParent(key)
      addUnique(key, value)
    end


    # accessor function, like hash, see examples. Local key overrides parent key.
    def [](key)
      # there are some cases to consider:
      #    * we have the key and return it or
      #    * we have do not have the key
      #      * we have no parent and return nil
      #      * we have a parent and recursively check for the key
      # if everything fails, we want to return a new String at least
      @hash[key] or (@parent ? @parent[key] : nil) or String.new
    end


    # accessor function, like hash. See examples of Config usage
    def []=(key, value)
      # we always assign, regardless of the parent, which may have the same key, as the keys
      # in this class override the parents keys (see also [](key))
      @hash[key] = value
    end


    # serializes this Config (without parents values, but mentioning parent name) into a string
    def to_s
      stringio = StringIO.new
      output(stringio)
      stringio.string
    end


    # serializes this Config (without parents values, but mentioning parent name) into the given io object
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


  protected  # comparable to private in C++ (after all, this is my primary language)

    def addChild(config)
      @childs.push(config)
    end


    def removeChild(config)
      @childs.delete(config)
    end

  end






  # Basic class and concept representing a node in the dependency DAG and any type of action that
  # needs to be performed (such as compilation of a source file). Each task can have a configuration
  # attached (see class Config)
  class Task

    # dependencies are of course tasks this task depends on. Additionally we have the array of
    # dependentTask that depend on this task (double-linked graph structure)
    attr_reader :name, :dependencies, :dependentTasks
    # targets is an Array of file names containing the targets produced by the task (may be empty if no files are produced)
    # this can be used to resolve dependencies on generated files
    attr_reader :targets
    # reference to Config object
    attr_accessor :config
    # these are used by the multi-threaded UpdateTraverser
    attr_accessor :mutex, :updateMark, :dependenciesUpdatedCount, :updateDuration
    # State has two purposes:
    #   -> it encodes an abstract representation of a node state in a string
    #      -> for leaf nodes this for example can be the md5-sum of a file (as in FileTask)
    #      -> for inner nodes, this typically is the concatenated states of childs upon successful update
    #         (see function concatStateOfDependenciess())
    #   -> it encodes successful update or not (in the latter case, state is nil). This means that
    #      Task instances should begin update() by setting state to nil and then setting a meaningful
    #      value upon successful update at the end of update() or in postUpdate()
    # Based on this semantics the state variable determines for inner nodes of the task graph,
    # if an update is necessary: upon a new build run, a necessary update can be detected by checking,
    # if the state matches the concatenated child states (see functions needsUpdate(),postUpdate())
    attr_reader :state


    # name must be unique within a build (see class Build)!
    def initialize(name, config = nil)
      @name = name
      @dependencies = Array.new
      @dependentTasks = Array.new
      @targets = Array.new

      @config = config

      # regarding the meaning of these see class UpdateTraverser
      @mutex = Mutex.new
      @updateMark = false
      @dependenciesUpdatedCount = 0
      @updateDuration = 1.0 # initial guess is one second (more of an integral countdown)
    end


    def addDependency(otherTask)
      if not @dependencies.index(otherTask) then
        @dependencies.push(otherTask)
        otherTask.dependentTasks.push(self)
      else
        # throw an exception ?
        Makr.log.warn("addDependency: Task with name #{otherTask.name} already exists as a dependency of task #{@name}.")
      end
    end


    # convenience function for adding a plethora of tasks
    def addDependencies(otherTasks)
      otherTasks.each {|task| addDependency(task) if not @dependencies.index(task) }
    end


    def removeDependency(otherTask)
      if @dependencies.index(otherTask) != nil then
        otherTask.dependentTasks.delete(self)
        @dependencies.delete(otherTask)
      else
        raise "[makr] Trying to remove a non-existant dependency!" # here we definitely raise an exception
      end
    end


    def clearDependencies()
      Makr.log.debug("clearing deps in: " + @name)
      while not @dependencies.empty?
        removeDependency(@dependencies.first)
      end
    end


    def clearDependantTasks()
      while not @dependentTasks.empty?
        @dependentTasks.first.removeDependency(self)  # this deletes @dependentTasks.first implicitely (see above)
      end
    end


    def clearAll()
      clearDependencies()
      clearDependantTasks()
    end


    # called by UpdateTraverser::Updater. Determines, if task needs a call to update(). This is not called
    # for leaf nodes of the dependency graph (tasks with no dependencies), as they are always updated.
    # Derived classes are free to override, a return value of true means that an update is necessary.
    def needsUpdate()
      return true if not @state
      return true if dependencies.empty? # although not called for leaf nodes, we keep this condition for safety
      dependenciesState = concatStateOfDependencies() # a little helper var for the next two test
      return false if not dependenciesState  # if one of our deps has an update error, it does not make sense to update
      return true if (@state != dependenciesState) # this is the central change detection
      return false # otherwise nothing changed and we dont need to update
    end


    # returns nil if task has no dependencies or if one of the dependencies has nil state, otherwise it
    # returns a concatenation of all the state strings of the dependencies.
    def concatStateOfDependencies()
      return nil if @dependencies.empty?
      retString = String.new
      # we sort by name to compensate changes in array order (name should be unique)
      localTaskArray = @dependencies.sort {|t1, t2| t1.name <=> t2.name}
      localTaskArray.each do |dep|
        return nil if not dep.state
        retString += dep.state
      end
      return retString
    end

    
    # used in UpdateTraverser::Updater
    def dependencyHadUpdateError()
      return false if @dependencies.empty? # no error, if we have no deps!
      @dependencies.each do |dep|
        return true if not dep.state
      end
      return false # no dependency had nil state, so everything is fine
    end
    
    
    def setErrorState()
      @state = nil
    end

    
    # Every subclass should provide an "update()" function, that performs an action that updates the Task
    # (like compilation etc.). The task graph itself should be unchanged during update as we do a multithreaded
    # update. Use function postUpdate() for this purpose.
    def update()
    end


    # The method postUpdate() is called after all tasks have been "update()"d. While update() is called in
    # parallel on the task graph and should not modify the graph, this function is called on all tasks in a
    # single thread in the sequence they have been updated (which is supposed to resemble the update()-dependency-order),
    # so that no issues with multi-threading can occur. Default behaviour is to concatenate the state of the
    # dependencies if the update has been successful (@state is not nil) and dependencies exist. This function
    # is for example overwritten in CompileTask to update the dependency list.
    def postUpdate()
      @state = concatStateOfDependencies() if @state and (not @dependencies.empty?)
    end


    # called once before build starts on all tasks of the build (mostly unused)
    def preUpdate()
    end


    # is always called just before the call to update(), if necessary, see UpdateTraverser::Updater::run()
    def deleteTargets()
      return if not @targets
      @targets.each do |target|
        File.delete target if File.exists? target
      end
    end


    # can be impletemented by subclasses indicating that this task is no longer valid due to for example a missing file
    def mustBeDeleted?()
      return false
    end


    def cleanupBeforeDeletion()  # interface mainly for tasks generating targets (removing these)
      deleteTargets()
    end


    # kind of debugging-"to_s"-function
    def printDependencies(prefix = "")
      Makr.log.info(prefix + @name + " deps size: " + @dependencies.size.to_s)
      @dependencies.each do |dep|
        dep.printDependencies(prefix + "  ")
      end
    end

  end






  # One of the central classes in Makr. Represents a variant build (in a given buildPath). Instances of Build
  # are stored using Makr.saveBuild and restored via Makr.loadBuild, which should be one of the first commands
  # in a Makrfile.rb. Without this cache, everything would be rebuild (no checking for existing targets etc.).
  # Additionally, this class provides automatic cleanup and pruning of the configs and tasks in the cache.
  # As Makr.saveBuild and Makr.loadBuild use the Marshall functionality of ruby, everything that is referenced
  # from the instance is saved and restored (which typically comprises almost all objects created in a Makrfile.rb).
  # To ensure that Makr.saveBuild is called, use a block with saveAfterBlock in the Makrfile.rb (just have a look
  # at the examples).
  class Build

    attr_reader   :buildPath, :postUpdates
    attr_accessor :configs
    attr_accessor :defaultTask, :nrOfThreads
    # hash from a file name to an Array of Task s (this is a kind of convenience member, see buildTasksForFile). It can
    # be used to realize the build of a single file provided by many IDEs)
    attr_accessor :fileHash
    # set this to true, if build should stop on first detected error (default behaviour)
    attr_accessor :stopOnFirstError
    # this is set to true if an error occured during the last build
    attr_reader :buildError


    # build path identifies the build directory where the cache of configs and tasks is stored in a
    # subdirectory ".makr" and loaded upon construction, if the cache exists (which is fundamental to the
    # main build functionality "rebuild only tasks, that need it").
    def initialize(buildPath) 
      @buildPath = Makr.cleanPathName(buildPath)
      @buildPath.freeze # make sure this isnt changed during execution

      @postUpdates = Array.new

      # hash from taskName to task (the cache is central to the update-on-demand-functionality and for automatic cleanup
      @taskHash      = Hash.new            # maps task names to tasks (names are for example full path file names)
      @taskHashCache = Hash.new            # a cache for the task hash that is loaded below
      @fileHash = Hash.new                 # convenience member, see above

      @stopOnFirstError = true
      @buildError = false

      @configs = Hash.new

      @defaultTask = nil
      @nrOfThreads = nil

      @accessMutex = Mutex.new # for synchronized accesses
    end


    # tasks is expected to be an Array of Task
    def pushTaskToFileHash(fileName, tasks)
      fileHash[fileName] ||= Array.new
      fileHash[fileName].concat(tasks)
      fileHash[fileName].uniq!
    end
    

    # block concept to ensure automatic save after block is done (should embrace all actions in a Makrfile.rb)
    def saveAfterBlock(cleanupConfigs = true)
      yield
    ensure
      Makr.saveBuild(self, cleanupConfigs)
    end


    # central function for building a given task. If task is not given, the defaultTask is used
    # or if even that one is not set, a root tasks with no dependent tasks is searched and
    # constructed. If even that fails, an exception is thrown.
    # The variable nrOfThreads influences, how many threads perform the update. If
    # no number is given, the number of available processors is used (see ThreadPool).
    def build(task = nil)
      @buildError = false
      updateTraverser = UpdateTraverser.new(@nrOfThreads)
      effectiveTask = nil
      if task then
        effectiveTask = task
      else
        # check default task or search for a single task without dependent tasks (but give warning)
        if @defaultTask.kind_of? Task then
          effectiveTask = @defaultTask
        else
          Makr.log.warn("no (default) task given for build, searching for root task")
          tasksFound = @taskHash.values.select {|v| v.dependentTasks.empty?}
          if tasksFound.size >= 1 then
            if tasksFound.size > 1 then
              Makr.log.warn("more than one root task found, taking the first found, which is: " + tasksFound.first.name)
            end
            effectiveTask = tasksFound.first
          else
            raise "[makr] failed with all fallbacks in Build.build"
          end
        end
      end

      # call preUpdate on all tasks before starting UpdateTraverser
      # we need to take care, that the taskHash might get modified during iteration, so Hash.values
      # returns a *new* array with all tasks at call time, on which we can safely iterate
      Makr.log.info( " \n\n ############################# doing preUpdate()  ###########################\n\n\n" )
      @taskHash.values.each {|task| task.preUpdate() }

      Makr.log.info( " \n\n ############################# doing update()     ###########################\n\n\n" )
      updateTraverser.traverse(self, effectiveTask)
      @buildError = (effectiveTask.state == nil)

      Makr.log.info( " \n\n ############################# doing postUpdate() ###########################\n\n\n" )
      doPostUpdates() if not @buildError

      # finally give message:
      if not UpdateTraverser.abortBuild and not @buildError then
        Makr.log.info("\n\n ############################# ;-) successfully build task ##################\n\n\n" )
      else
        Makr.log.info("\n\n oooooo    oooooo    ooooo     :(  ERROR on building task  oooooo   oo oo ooo\n\n\n" )
      end
    end


    # this function is called with the name of a source file and builds all associated tasks and their dependencies
    # (which typically amounts to the compilation of a single file)
    def buildTasksForFile(fileName)
      if not @fileHash[fileName]
        raise "[makr] fileName not found in buildTasksForFile(fileName), maybe you added tasks without using Generators or" \
              " the ones you used are not compliant"
      end
      @fileHash[fileName].each do |task|
        build(task)
      end
    end


    def resetUpdateMarks()
      @taskHash.each_value do |value|
        value.updateMark = false
      end
    end


    def registerPostUpdate(task)
      @accessMutex.synchronize { @postUpdates.push(task) }
    end


    def doPostUpdates()
      @postUpdates.each do |task|
        task.postUpdate()
      end
      @postUpdates.clear() # afterwards, we clear the array
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
        raise "[makr] Task not found! " + taskName
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


    # this is not the same as fileHash, as it looks at the targets of all tasks
    def getTaskForTarget(fileName)
      @taskHash.each_value do |task|
        return task if (task.targets and task.targets.include?(fileName))
      end
      nil
    end


    # This function wants a block, use it like this:
    #    build.getOrMakeNewTask(name) {MyTask.new(arg1,arg2, ...)}
    # The function first searches for task with the given name and returns it, if found. If not, it creates a
    # new Task by executing the user-provided block and returns that one.
    def getOrMakeNewTask(name)
      if not hasTask?(name) then
        task = yield
        addTask(name, task)
      end
      return getTask(name)
    end


    def hasConfig?(name)
      return @configs.has_key?(name)
    end


    def addConfig(config)
      Makr.log.warn("Overwriting config with name " + config.name) if hasConfig?(config.name)
      @configs[config.name] = config
    end


    def getConfig(name)
      if not hasConfig?(name) then
        raise "[makr] no such config: " + name
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
      if hasConfig?(name) then # already have this config
        config = getConfig(name)
      else
        parentName = task.config.name if task.config
        config = makeNewConfig(name, parentName)
      end
      return task.config = config
    end


    # dump helper functions


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
        deleteArr.concat(task.dependentTasks) # pickup dependentTasks, which need to be deleted, too
        task.cleanupBeforeDeletion() # do last cleanups
        task.clearAll()  # untie all connections
      end
    end


    def cleanConfigs()
      saveHash = Hash.new
      @taskHash.each do |key, value|
        if value.config and not (saveHash.has_key?(value.config.name)) then # save each config once
          saveHash[value.config.name] = value.config
          @configs.delete(value.config.name)
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


    def prepareDump()
      @taskHashCache.replace(@taskHash)
      @taskHash.clear()
      unsetMutexes()
    end


    def unprepareDump()
      @taskHash.replace(@taskHashCache)
      @taskHashCache.clear()
      setMutexes()
    end


    def setMutexes()
      @taskHash.each_value do |value|
        value.mutex = Mutex.new
      end
      @taskHashCache.each_value do |value|
        value.mutex = Mutex.new
      end
      @accessMutex = Mutex.new
    end
      

    def unsetMutexes()
      @taskHash.each_value do |value|
        value.mutex = nil
      end
      @taskHashCache.each_value do |value|
        value.mutex = nil
      end
      @accessMutex = nil
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


    
  end  # end of class Build



  


  # Constructs a build from the caches found in the ".makr"-subDir in the given buildPath, if they
  # exist. Otherwise makes everything new (dirs and Build object). In either case, a Build object
  # is returned.
  def Makr.loadBuild(buildPath)
    buildPath = Makr.cleanPathName(buildPath)
    buildPathMakrDir = buildPath + "/.makr"
    # if build dir and subdirs does not exist, create it
    raise "[makr] given build dir is not a dir!" if (not File.directory?(buildPath)) and File.exist?(buildPath)
    Dir.mkdir(buildPath) if not File.directory?(buildPath)
    raise "[makr] \"" + buildPath + "/.makr\" is not a dir!" \
      if (not File.directory?(buildPathMakrDir)) and File.exist?(buildPathMakrDir)
    Dir.mkdir(buildPathMakrDir) if not File.directory?(buildPathMakrDir)

    buildPathBuildDumpFileName = buildPathMakrDir + "/build.ruby_marshal_dump"

    if not File.file?(buildPathBuildDumpFileName) then
      Makr.log.warn("could not find or open build dump file, build will be setup new!")
      return Build.new(buildPath) 
    end
    Makr.log.info("found build dump file, now restoring")
    File.open(buildPathBuildDumpFileName, "rb") do |dumpFile|
      build = Marshal.load(dumpFile)
      build.cleanTaskHashCache()
      build.setMutexes()
      return build
    end
  end


  # Saves the Build to the ".makr"-subdir of the buildPath. 
  def Makr.saveBuild(build, cleanupConfigs = true)
    # we exclude the fileHash from the saved data (as it is just convenience and we want to avoid a synchronization mess)
    localFileHash = build.fileHash
    build.fileHash = Hash.new
    build.cleanConfigs() if cleanupConfigs
    build.prepareDump() # exchanges task hashes so that upon load all that is now in taskHash is then in taskHashCache
    saveFileName = build.buildPath + "/.makr/build.ruby_marshal_dump"
    File.open(saveFileName, "wb") do |dumpFile|
      Marshal.dump(build, dumpFile)
    end

    # as the user may use the build after save, we restore everything
    build.unprepareDump() 
    build.fileHash = localFileHash
  end







  # This class realizes the multi-threaded update step.
  # It can be used stand-alone, but typically calling Build::build() is the standard way to do it.
  class UpdateTraverser

    # this class variable is used to realize cooperative build abort, see Makr::abortBuild()
    @@abortBuild = false
    def UpdateTraverser.abortBuild
      @@abortBuild
    end
    def UpdateTraverser.abortBuild=(arg)
      @@abortBuild = arg
    end

    # we use this to provide a countdown functionality for a parallel build in the log output
    # similar to what cmake provides with a percentage upcount. We count down the number of tasks
    # that need to be done, so its always correct in the sense that it comes down to zero at the
    # end of a build
    # ( see references to UpdateTraverser.timeToBuildDownRemaining at the end of this script to see how the
    #  output is generated )
    @@timeToBuildDownRemaining = 0
    def UpdateTraverser.timeToBuildDownRemaining
      @@timeToBuildDownRemaining
    end
    def UpdateTraverser.timeToBuildDownRemaining=(arg)
      @@timeToBuildDownRemaining = arg
    end
    @@timeToBuildDownRemainingMutex = Mutex.new
    def UpdateTraverser.timeToBuildDownRemainingMutex
      @@timeToBuildDownRemainingMutex
    end


    # nested class representing a single task update, executed in a thread pool
    class Updater

      def initialize(task, build, threadPool, stopOnFirstError)
        @task = task
        @build = build
        @threadPool = threadPool
        @stopOnFirstError = stopOnFirstError
      end


      # we need to go up the tree with the traversal even in case dependency did not update or had an error upon update
      # just to increase the dependenciesUpdatedCount in each marked node so that in case
      # of the update of a single (sub-)dependency, the node will surely be updated or an update error is handled!
      # An intermediate node up to the root might not be updated, as it need not, but the algorithm logic
      # still needs to handle dependent tasks for the above reason.
      def run()
        @task.mutex.synchronize do
          raise "[makr] Unexpectedly starting on a task that needs no update!" if not @task.updateMark # some sanity check
          @task.updateMark = false
          daDoRunRunRun() # see immediately below
        end
      end


      def daDoRunRunRun()
        # as we will have done a task (wether it was updated or not doesnt matter), we want to decrease the timeToBuildDownRemaining
        # we scale by the nrOfThreads employed (ok, this is not a linear speedup, but close to it). As we decrease in parallel, we
        # need the mutex here.
        UpdateTraverser.timeToBuildDownRemainingMutex.synchronize do
          UpdateTraverser.timeToBuildDownRemaining -= @task.updateDuration / @threadPool.nrOfThreads
          UpdateTraverser.timeToBuildDownRemaining = 0.0 if (UpdateTraverser.timeToBuildDownRemaining < 3.0)
        end

        if @task.dependencyHadUpdateError() then
          @task.deleteTargets()
          @task.setErrorState() # set update error on this task too, as a dependency had an error (ERROR PROPAGATION)
        else

          # do we need to update?
          if (@task.dependencies.empty? or @task.needsUpdate()) and not UpdateTraverser.abortBuild then
            # we update expected duration when task is updated, so that only the last measured time is used the next time
            t1 = Time.now
            # we always delete targets before update, Task classes that do not want this, should overwrite the function
            @task.deleteTargets()
            @task.update()
            @task.updateDuration = (Time.now - t1)
            # check for update error
            UpdateTraverser.abortBuild = true if @stopOnFirstError and not @task.state
          end
          @build.registerPostUpdate(@task) if @task.state

        end

        @task.dependentTasks.each do |dependentTask|
          dependentTask.mutex.synchronize do
            if dependentTask.updateMark then # only work on dependent tasks that want to be updated
              # if we are the last thread to reach the dependent task, we will run the next thread on it
              dependentTask.dependenciesUpdatedCount = dependentTask.dependenciesUpdatedCount + 1
              if (dependentTask.dependenciesUpdatedCount == dependentTask.dependencies.size) then
                updater = Updater.new(dependentTask, @build, @threadPool, @stopOnFirstError)
                @threadPool.execute {updater.run()}
              end
            end
          end
        end

      end

    end # end of nested class Updater


    def initialize(nrOfThreadsInPool = nil)
      @threadPool = ThreadPool.new(nrOfThreadsInPool)
    end


    # root must be a task. The traversal works as follows: we walk down the DAG until we reach
    # tasks with no dependencies. Upon this walk we mark all tasks we visit. Then, from the
    # independent tasks, we walk up again and run an Updater thread on each marked node. The number
    # of threads is limited by a thread pool.
    #
    # TODO: We expect the DAG to have no cycles here. Should we check?
    def traverse(build, root)
      build.resetUpdateMarks()
      # reset the count that represents the nr of tasks that are affected by this update
      @@timeToBuildDownRemaining = 0.0
      collectedTasksWithNoDeps = Array.new
      recursiveMarkAndCollectTasksWithNoDeps(root, collectedTasksWithNoDeps)
      collectedTasksWithNoDeps.uniq!
      Makr.log.info("collectedTasksWithNoDeps.size: " + collectedTasksWithNoDeps.size.to_s)
      collectedTasksWithNoDeps.each do |noDepsTask|
        updater = Updater.new(noDepsTask, build, @threadPool, build.stopOnFirstError)
        @threadPool.execute {updater.run()}
      end
      @threadPool.join()
    end


    # internal helper function (see also traverse(root) )
    def recursiveMarkAndCollectTasksWithNoDeps(task, collectedTasksWithNoDeps)
      return if task.updateMark # task was already marked and thus we dont need to descend
      # prepare the task variables upon descend
      task.updateMark = true
      task.dependenciesUpdatedCount = 0
      # each task that we mark gets touched by Updater, so we increase timeToBuildDownRemaining by the
      # number of seconds estimated in previous builds (see Updater.run)
      # we scale by the nrOfThreads employed (ok, this is not a linear speedup, but close to it)
      @@timeToBuildDownRemaining += task.updateDuration / @threadPool.nrOfThreads

      # then collect, if no further deps or recurse
      if task.dependencies.empty? then
        collectedTasksWithNoDeps.push(task)
        return
      end
      task.dependencies.each{|dep| recursiveMarkAndCollectTasksWithNoDeps(dep, collectedTasksWithNoDeps)}
    end

  end















  # --
  # [ RDoc stops processing comments if it finds a comment line containing '#--'
  # Commenting can be turned back on with a line that starts '#++'. ]
  #
  # now some basic classes follow that are derived from Task
  #
  # ++





  # This class represents the dependency on changed strings in a Config, it is used for example in CompileTask
  class ConfigTask < Task

    # make a unique name for CompileTasks out of the fileName which is to be compiled
    def ConfigTask.makeName(name)
      "ConfigTask__" + name
    end


    def initialize(name)
      super
    end


    def update()
      # produce a nice message in error case (we want exactly one dependent task)
      raise "[makr] ConfigTask #{name} does not have a dependent task, but needs one!" if (not (dependentTasks.size == 1))

      # just update state with config string from the only dependentTask
      # getConfigString() is supposed to NOT deliver a nil object, but at least an empty String
      @state = dependentTasks.first.getConfigString()
    end

  end








  # Represents simple and basic dependencies on a files (could be input or output). set class variable FileTask.useFileHash to
  # true (default is false) to check file change by md5-summing (is a costly operation)
  class FileTask < Task

    # this variable states, if file hashes should be used to identify changed files (which can be a costly operation)
    @@useFileHash = false
    def FileTask.useFileHash
      @@useFileHash
    end
    def FileTask.useFileHash=(arg)
      @@useFileHash = arg
    end


    attr_reader :fileName, :time, :size, :fileHash, :missingFileIsError
    attr_accessor :useFileHash # for setting hash usage individually, overrides class variable


    # the boolean argument missingFileIsError can be used to indicate, if an update is necessary, if file is missing
    # (which is the "false" case) or if it is an error and the build should abort. In other words: if missingFileIsError
    # is false, a missing file just means that the update function will return true. This can be used for targets of
    # the build process (see also class CompileTask for a usage example), to indicate a target that needs to be produced.
    def initialize(fileName, missingFileIsError = true)
      @fileName = Makr.cleanPathName(fileName)
      super(@fileName)
      # all file attribs stay uninitialized, so that first call to update returns true
      @time = @size = @fileHash = String.new
      @missingFileIsError = missingFileIsError
      Makr.log.debug("made file task with @fileName=\"" + @fileName + "\"")
    end


    def mustBeDeleted?()
      if (not File.file?(@fileName)) and (@missingFileIsError) then
          Makr.log.info("mustBeDeleted?() is true for missing file: " + @fileName)
          return true
      end
      return false
    end


    def update()
      # first check missing file case
      if (not File.file?(@fileName)) then
        if @missingFileIsError then # error case
          Makr.log.error("FileTask #{@name}: file is unexpectedly missing!")
          @state = nil
          return
        end
        # "success" case
        Makr.log.debug("FileTask #{@name}: file is missing.")
        @state = String.new # missing file has no specific state
        return
      end

      # now we either use the hash of the file or we use file attributes to determine changes
      unless @useFileHash.is_a? NilClass then # the local variable overrides class variable if set
        useFileHash = @useFileHash
      else
        useFileHash = @@useFileHash
      end

      hasChanged = false # used only for output below

      if useFileHash then                     # file hash
        curHash = MD5.new(open(@fileName, 'rb').read).hexdigest
        if(@fileHash != curHash)
          @fileHash = curHash
          @state = " FileHash: " + @fileHash  # compose state from file state
          hasChanged = true
        end

      else                                    # file attribs checking
        stat = File.stat(@fileName);
        if (@time != stat.mtime) or (@size != stat.size) then
          @time = stat.mtime
          @size = stat.size
          @state = " File attribs: " + @time.to_s + " " + @size.to_s # compose state from file state
          hasChanged = true
        end
      end
      Makr.log.debug("FileTask #{@name}: file #{@fileName} has changed.") if hasChanged
    end

  end















  #--
  #
  # build construction helper classes
  #
  #++




  # Helps collecting files given directories and patterns. All methods are static.
  # I did not use find from ruby standard library, as I needed more flexibility (patterns,
  # non-recursive directory lists, etc.)
  class FileCollector


    # dirName is expected to be a path name, pattern could be "*" or "*.cpp" or "*.{cpp,cxx,CPP}", etc.
    def FileCollector.collect(dirName, pattern = "*", recurse = true)
      fileCollection = Array.new
      privateCollect(dirName, pattern, nil, fileCollection, recurse)  # exclusion pattern is empty
      return fileCollection
    end


    # convenience methods
    def FileCollector.collectRecursive(dirName, pattern = "*")
      return FileCollector.collect(dirName, pattern, true)
    end
    def FileCollector.collectFlat(dirName, pattern = "*")
      return FileCollector.collect(dirName, pattern, false)
    end


    # additional collector with exclusion pattern given
    def FileCollector.collectExclude(dirName, pattern, exclusionPattern, recurse = true)
      fileCollection = Array.new
      privateCollect(dirName, pattern, exclusionPattern, fileCollection, recurse)
      return fileCollection
    end


  protected


    def FileCollector.privateCollect(dirName, pattern, exclusionPattern, fileCollection, recurse)

      return if UpdateTraverser.abortBuild # check if build was aborted before proceeding

      dirName = Makr.cleanPathName(dirName)
      # first recurse into sub directories
      if recurse then
        Dir[dirName + "/*/"].each do |subDir|
          privateCollect(subDir, pattern, exclusionPattern, fileCollection, recurse)
        end
      end
      if exclusionPattern and not exclusionPattern.empty? then
        files = Dir[ dirName + "/" + pattern ]
        exclusionFiles = Dir[ dirName + "/" + exclusionPattern ]
        files.each do |fileName|
          fileCollection.push(fileName) if (File.file?(fileName) and not exclusionFiles.include?(fileName))
        end
      else
        fileCollection.concat(Dir[ dirName + "/" + pattern ])
      end
    end

  end







  # Can be called with an array of file names in fileCollection (as produced by FileCollector for example)
  # or just a single file name.
  # On each file in fileCollection, all generators from generatorArray are executed. During this (maybe lengthy) operation,
  # the build could be aborted (for example by user request or fatal generator error). This function returns an array of
  # tasks that have been generated. These are typically added as dependencies to another task (for example a ProgramTask),
  # by using Task::addDependencies(otherTasks).
  def Makr.applyGenerators(fileCollection, generatorArray)
    # first check, if we only have a single file
    fileCollection = [Makr.cleanPathName(fileCollection)] if fileCollection.kind_of? String
    tasks = Array.new
    fileCollection.each do |fileName|
      generatorArray.each do |gen|
        return tasks if UpdateTraverser.abortBuild # cooperatively abort build
        genTasks = gen.generate(fileName)
        tasks.concat(genTasks)
      end
    end
    return tasks
  end
















  # The following classes are for script argument management, a facility for calling subdir-Makrfiles.
  # This mechanism is even used for calling the Makrfile.rb in the current directory, which is the
  # start of every makr-execution.

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
      Makr.log.fatal("In Makr.popArgs(): tried to remove the last arguments from stack, exiting!")
      Makr.abortBuild()
    end
    ScriptArgumentsStorage.get.pop
  end


  def Makr.getArgs()
    ScriptArgumentsStorage.get.last
  end







  @@madeDirs = Array.new

  # loads a Makrfile.rb from the given dir and executes it using Kernel.load and push/pops the current ScriptArguments
  def Makr.makeDir(dir, additionalArguments = getArgs().arguments.clone)

    # check if build was aborted before proceeding
    return if UpdateTraverser.abortBuild 

    # check, if we already made this subdir (this helps avoiding multiple build calls on dependent subdirs)
    checkDir = Dir.pwd + "/" + dir
    return if @@madeDirs.include? checkDir
    @@madeDirs.push(checkDir)

    # then do subdir
    dir = Makr.cleanPathName(dir)
    oldDir = Dir.pwd
    Dir.chdir(dir)
    makrFilePath = "./Makrfile.rb"
    if File.exist?(makrFilePath) then
      Makr.pushArgs(Makr::ScriptArguments.new(makrFilePath, additionalArguments))
      Kernel.load(makrFilePath, true)  # second parameter sayz to wrap an anonymous module around the called script content
      popArgs()
    else
      Makr.log.fatal("Cannot find Makrfile-Path " + makrFilePath + " from current working dir " + Dir.pwd + "!")
      Makr.abortBuild()
    end
    Dir.chdir(oldDir)
  end



  #--
  #
  # some internal helper functions follow
  #
  #++



  # some global variable setup
  def Makr.setMakrGlobalVars()
    # for the following variable, we care for symlinks only, hardlinks will go wrong
    # (TODO: maybe we need an environment var here or something hardcoded in this file?)
    unless File.symlink?(__FILE__) then
      $makrDir = File.dirname(__FILE__)
    else
      makrLinkPath = File.readlink(__FILE__) # makrLinkPath can be absolute or relative!
      if makrLinkPath.index('/') == 0 then
        $makrDir = File.dirname(makrLinkPath)
      else
        $makrDir = File.dirname(__FILE__) + "/" + File.dirname(makrLinkPath)
      end
    end
    $makrDir = File.expand_path($makrDir) # kill relative paths
    $makrExtensionsDir = $makrDir + "/extensions"
  end


  # used for clean abortion of build for example through IDEs
  def Makr.setSignalHandler()
    abort_handler = Proc.new do
      Makr.log.fatal("Aborting build on signal USR1 or TERM")
      Makr.abortBuild()
    end
    Signal.trap("USR1", abort_handler)
    Signal.trap("TERM", abort_handler)
  end







  # very very simple extension system (plugin system), safeguarded against multiple extension loading
  @@loadedExtensions = Array.new
  # loads the given extension from the extensions subdirectory of a makr-installation
  def Makr.loadExtension(exName)
    unless @@loadedExtensions.include?(exName) then
      Kernel.load($makrExtensionsDir + "/" + exName + ".rb") # regarding $makrExtensionsDir, see setMakrGlobalVars()
      @@loadedExtensions.push(exName)
    end
  end

  # some helper functions for extension scripts (and maybe user scripts) to check for dependencies
  def Makr.isAnyOfTheseExtensionsLoaded?(exList)
    exList.each { |exName | return true if @@loadedExtensions.include?(exName) }
    return false
  end
  # read-only access (making a depp copy)
  def Makr.loadedExtensions()
    @@loadedExtensions.map {|m| m.clone}
  end




  
  
  
  
  
  
  
  # utility function to reduce a build's load on the system (using renice and ionice (Linux only))
  def Makr.doNiceBuild()
    system("renice -n 19 -p #{Process.pid};ionice -c 3 -p #{Process.pid}")
  end
  
  
  
  
  
  
  


end     # end of module makr ######################################################################################








####################################################################################################################

# MAIN logic and interface with client code following

####################################################################################################################

# first start logger and set start logging level (can of course be changed by user)
Makr.log.level = Logger::DEBUG
Makr.log.formatter = proc { |severity, datetime, progname, msg|
    "[makr #{severity} #{datetime}] [#{Makr::UpdateTraverser.timeToBuildDownRemaining}]    #{msg}\n"
}
# just give short version notice on every startup
Makr.log << "\n\nmakr version 1.4\n\n"
# then set the signal handler to allow cooperative aborting of the build process on SIGUSR1 or SIGTERM
Makr.setSignalHandler()
# set global vars
Makr.setMakrGlobalVars()
# we need at least one ScriptArguments object pushed to stack (kind of dummy holding ARGV)
# we use a relative path here to allow moving of build dir
Makr.pushArgs(Makr::ScriptArguments.new("./Makrfile.rb", ARGV))
# then we reuse the makeDir functionality building the current directory
Makr.makeDir(".")
