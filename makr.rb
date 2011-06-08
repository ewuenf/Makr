#!/usr/bin/ruby


# this will be my ruby-based build tool, I hereby name it "makr" and it will read "Makrfiles", uenf!




require 'thread'
require 'md5'




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


  






  class Task
    
    attr_reader :name, :dependencies, :dependantTasks
    # these are used by the multi-threaded UpdateTraverser
    attr_accessor :mutex, :updateMark, :dependenciesUpdatedCount, :dependencyWasUpdated

    def initialize(name)
      @name = name
      @dependencies = Array.new
      @dependantTasks = Array.new

      @mutex = Mutex.new
      @updateMark = false
      @dependenciesUpdatedCount = 0
      @dependencyWasUpdated = false
    end

    
    def addDependency(otherTask)
      if(dependencies.index(otherTask) == nil)
        @dependencies.push(otherTask)
        otherTask.dependantTasks.push(self)
      end
      # we dont do anything if a task wants to be added twice, they are unique, maybe we should log this
    end

    
    def removeDependency(otherTask)
      if(dependencies.index(otherTask) != nil)
        otherTask.dependantTasks.delete(self)
        @dependencies.delete(otherTask)
      else
        raise "Trying to remove a non-existant dependency!" # here we definitely raise an exception
      end
    end

    
    def clearDependencies()
      while not dependencies.empty?
        removeDependency(dependencies.first)
      end
    end

    # every subclass should provide an "update()" function, that returns wether the target of the task was updated
    # this is the default implementation
    def update() 
      false
    end
    
  end




  class FileTask < Task

    attr_reader :fileName, :time, :size, :fileHash # absolute path for fileName expected!

    def initialize(fileName)  # absolute path for fileName expected!
      @fileName = fileName
      puts "[makr] made file task with @fileName=\"" + @fileName + "\""
      super(@fileName)
      # all file attribs stay uninitialized, so that first call to update returns true
      @time = @size = @fileHash = String.new
    end

    
    def update()
      print "[makr] checkin FileTask " + fileName + "  "
      retValue = false
      curTime = File.stat(@fileName).mtime
      if(@time != curTime)
        @time = curTime
        puts "[makr] FileTask, mtime changed: " + @fileName
        retValue = true
      end
      curSize = File.stat(@fileName).size
      if(@size != curSize)
        #puts "[makr] FileTask, size changed: " + @fileName + " oldSize = " + @size + " newSize = " + curSize
        @size = curSize
        retValue = true
      end
      curHash = MD5.new(open(@fileName, 'rb').read).hexdigest
      if(@fileHash != curHash)
        puts "[makr] FileTask, hash changed: " + @fileName + " oldHash = " + @fileHash #+ " newSize = " + curHash
        @fileHash = curHash
        retValue = true
      end
      puts retValue
      return retValue
    end
  end


  
  
  # This class not only checks for file attributes on update but also return true in update(), when the
  # file does not exist at all (a FileTask
  class FileExistenceTask < FileTask

    def initialize(fileName)
      puts "new file existence task: " + fileName
      super(fileName)
    end

    def update()
      puts "checking file existence task: " + @fileName
      if (not File.file?(@fileName))
        return true;
      else
        return super
      end
    end
  end


  

  # can be attached to a Build as globalConfig, to a CompileTask or a BuildTask as specific config
  class Config

    # otherOptions is just a hash (string -> string) where users can specifiy arbitrary values to be used
    # in their own subclasses
    attr_accessor :compilerCommand, :cFlags, :defines, :includePaths, :otherOptions

    def initialize()
      @compilerCommand = "g++ "                        # default val
      @cFlags = @defines = @includePaths = String.new  # default is empty
    end
  end




  # represents a cpp-file that has source-code-induced dependencies (and any that a user may specify)
  # input files are dependencies on FileTasks
  class CompileTask < Task

    # class vars and functions
    @@checkOnlyUserHeaders = false
    def self.checkOnlyUserHeaders
      @@checkOnlyUserHeaders
    end

    # make a unique name for CompileTasks out of the fileName which is to be compiled
    def self.makeName(fileName)
      fileName + "__CompileTask"
    end


    # the absolute path of the input and output file of the compilation
    attr_reader :fileName, :objectFileName, :compileTarget
    
    # build contains the global configuration, see Build.globalConfig and class Config
    def initialize(fileName, build)
      @fileName = fileName
      # now we need a unique name for this task. As we're defining a FileTask as dependency to fileName
      # and a FileExistenceTask on the @objectFileName to ensure a build of the target if it was deleted or
      # otherwise modified (whatever you can think of here), we create a unique name
      super(CompileTask.makeName(@fileName))
      puts "[makr] made CompileTask with @name=\"" + @name + "\""

      @build = build

      # we just keep it simple for now and add a ".o" to the given fileName, as we cannot safely replace a suffix
      @objectFileName = @build.buildPath + "/" + File.basename(@fileName) + ".o"
      @compileTarget = FileExistenceTask.new(@objectFileName)
      @build.taskHash[@objectFileName] = @compileTarget

      @config = @build.globalConfig
      
      buildDependencies()
    end

    
    # a config may be a specific config per CompileTask, default is to reference build.globalConfig
    # once this function is called, the task has a local config
    def getLocalConfig()
      if(@config == @build.globalConfig)
        @config = @build.globalConfig.clone
      end
      @config
    end


    def buildDependencies()
      clearDependencies()
      # we use the compiler for now, but maybe fastdep is worth a look / an adaption
      # we are excluding system headers for now (option "-MM"), but that may not bring performance, then use option "-M"
      dependOption = " -M "
      if @@checkOnlyUserHeaders
        dependOption = " -MM "
      end
      depCommand = @config.compilerCommand + dependOption + @config.cFlags + " " + @config.defines + " " \
                   + @config.includePaths + " " + @fileName
      puts "[makr] Executing compiler to check for dependencies in CompileTask: \"" + @fileName + "\"\n\t" + depCommand
      compilerPipe = IO.popen(depCommand)  # in ruby >= 1.9.2 we could use Open3.capture2(...) for this purpose
      dependencyLines = compilerPipe.readlines
      if dependencyLines.empty?
        puts "[makr] Error in CompileTask: \"" + @fileName + "\" making dependencies failed, check file!"
        exit 1 # should this be a hard error or should we continue gracefully?
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
        if @build.taskHash.has_key?(depFile)
          task = @build.taskHash[depFile]
          if not @dependencies.include?(task)
            addDependency(task)
          end
        else
          @build.taskHash[depFile] = task = FileTask.new(depFile)
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
      compileCommand = @config.compilerCommand + " -c " + @config.cFlags + " " + @config.defines + " " \
                       + @config.includePaths + " " + @fileName + " -o " + @objectFileName
      puts "[makr] Executing compiler in CompileTask: \"" + @fileName + "\"\n\t" + compileCommand
      successful = system(compileCommand)
      if not successful
        puts "\n\n\n\nerror, exiting build process\n\n\n"
        Kernel.exit!(1)
      end
      @compileTarget.update() # we call this to update file information on the compiled target
      return true # right now, we are always true (we could check for target equivalence or something else)
    end
    
  end



  
  class BuildTask < Task
    def initialize(name)
      super(name)
    end
  end



  
  class DynamicLibTask < BuildTask
    # special dynamic lib thingies
    def initialize(libName)
      raise "Not implemented yet"
    end
  end



  
  class StaticLibTask < BuildTask
    # special static lib thingies
    def initialize(libName)
      raise "Not implemented yet"
    end
  end


  

  class ProgramTask < BuildTask

    attr_reader    :programName  # identifies the binary to be build, wants full path as usual
    attr_accessor  :lFlags       # special linker flags
    attr_accessor  :libPaths     # special linker paths
    attr_accessor  :libs         # libs to be linked to the binary

    def initialize(programName, build)
      @programName = programName
      super(@programName)
      @build = build
      @lFlags = @libPaths = @libs = String.new
    end
    

    def update()
      # build compiler command and execute it
      compileCommand = @build.globalConfig.compilerCommand + " " + @lFlags + " " + @libPaths + " " + @libs + " -o " + @programName
      @dependencies.each {|dep| compileCommand += " " + dep.objectFileName}
      puts "[makr] Building programTask \"" + @name + "\"\n\t" + compileCommand
      system(compileCommand)
      return true # this is always updated
    end
    
  end

  

  
  class Build
    
    attr_accessor :globalConfig
    attr_accessor :taskHash        # maps task names to tasks (names are typically full path file names)
    attr_reader   :tashHashFile    # where the task hash is stored to
    attr_reader   :buildPath       # build path should be absolute and is read-only once set in ctor
    attr_reader   :target          # a build task is expected here

    
    def initialize(buildPath)
      @globalConfig = Config.new
      @taskHash = Hash.new
      @buildPath = buildPath
      @buildPath.freeze # set readonly
      @taskHashFile = @buildPath + "/taskHash.ruby_marshal_dump"
      loadTaskHash()
    end

    
    def loadTaskHash()
      puts "[makr] trying to read task hash from " + @taskHashFile
      if File.file?(@taskHashFile)
        puts "[makr] found taskHash file, now restoring\n\n"
        File.open(@taskHashFile, "rb") do |dumpFile|
          @taskHash = Marshal.load(dumpFile)
        end
      else
        puts "\n\n[makr] could not find or open taskHash file, tasks will be setup new!\n\n"
      end
    end

    
    def dumpTaskHash()
      # first cleanup task hash (remove tasks with no dependants and dependencies, "dangling tasks")
      # then dump the hash using Marshal.dump
      @taskHash.delete_if { |name, task| (task.dependantTasks.empty? and task.dependencies.empty?)}
      File.open(@taskHashFile, "wb") do |dumpFile|
        Marshal.dump(@taskHash, dumpFile)
      end
    end


    def setTarget(buildTask)
      @target = buildTask
      @taskHash[@target.name] = @target
    end
    
  end



#we want to refine the task generator to be a client to the Find module and reduce the interface to the proper
 # handling of a single file given the parameters it needs (at least a Build object)


  class RecursiveCompileTaskGenerator
    # expects an absolute path in dirName, where to find the files matching the pattern and adds all CompileTask objects to
    # the taskHash of build and returns the list of CompileTasks made
    def generate(dirName, pattern, build)
      compileTasksArray = Array.new
      recursiveGenerate(dirName, pattern, build, compileTasksArray)
      compileTasksArray
    end
    
    def recursiveGenerate(dirName, pattern, build, compileTasksArray)
      Dir.chdir(dirName)

      # recurse
      subDirs = Dir['*/']
      subDirs.each {|subDir|
                    #puts "[makr] recursing into subdir: " + subDir
                    recursiveGenerate(dirName + subDir, pattern, build, compileTasksArray)
                   } 

      # catch all files matching the pattern
      matchFiles = Dir[pattern]
      matchFiles.each {|fileName|
                       fullFileName = (dirName + fileName).strip
                       compileTaskName = CompileTask.makeName(fullFileName)
                       if not build.taskHash.has_key?(compileTaskName)
                         #puts "[makr] making NEW compile task for file: \"" + fullFileName + "\""
                         build.taskHash[compileTaskName] = CompileTask.new(fullFileName, build)
                       end
                       compileTasksArray.push(build.taskHash[compileTaskName])
                      }
      #puts "[makr] returning from subdir: " + dirName
      Dir.chdir("..")
    end
  end



  
  class ProgramGenerator
    def self.generate(dirName, pattern, build, progName)
      recursiveCompileTaskGenerator = RecursiveCompileTaskGenerator.new
      compileTasksArray = recursiveCompileTaskGenerator.generate(dirName, pattern, build)
      progName.strip!
      if not build.taskHash.has_key?(progName)
        puts "[makr] making NEW program task with name: \"" + progName + "\""
        build.taskHash[progName] = ProgramTask.new(progName, build)
      end
      programTask = build.taskHash[progName]
      build.setTarget(programTask)
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
                dependantTask.dependenciesUpdatedCount = dependantTask.dependenciesUpdatedCount + 1
                if (dependantTask.dependencyWasUpdated or retVal)
                  dependantTask.dependencyWasUpdated = true
                end
                # if we are the last thread to reach the dependant task, we will run the next thread
                # on it. The dependant task needs to be updated if at least a single dependency task
                # was update (which may not be the task of this thread)
                if (dependantTask.dependenciesUpdatedCount == dependantTask.dependencies.size)
                  updater = Updater.new(dependantTask, @threadPool)
                  @threadPool.execute {updater.run(dependantTask.dependencyWasUpdated)}
                end
              end
            end
          end
        end  
      end
      
    end # end of class Updater

    
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
      puts "now unifying"
      collectedTasksWithNoDeps.uniq!
      puts "collectedTasksWithNoDeps.size: " + collectedTasksWithNoDeps.size.to_s
      collectedTasksWithNoDeps.each do |noDepsTask|
        #puts "[makr] Starting noDepsTask " + noDepsTask.to_s + noDepsTask.name + " in a thread"
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

  # just a convenience function, loads a Makrfile.rb from the given subDir and executes it
  def makeSubDir(subDir)
    $makrFilePath = subDir + "/Makrfile.rb"
    Kernel.load($makrFilePath)
  end

end     # end of module makr





################################################################## main logic interfacing with client code following

puts "makr version 2011.5.22" # just give short version notice on every startup (Date-encoded)

# set global vars available to the code in the Makrfile and each dependent Makrfile based on the command line
# arguments to this script, everything that begins with a "$" in the following is available to client code in Makrfile.rb
$makrProgram = $0
$makrFilePath = Dir.pwd + "/Makrfile.rb"
$commandLineArgs = ARGV
# now we load the Makrfiles and use Kernel.load on them to execute them as ruby scripts
Kernel.load($makrFilePath)

