

module Makr





  class SourceStats

    @@statsFile = nil


    def SourceStats.createStatsFile(fileName)
      @@statsFile = File.new(fileName, File::CREAT|File::TRUNC|File::RDWR)
    end

    def SourceStats.closeStatsFile()
      @@statsFile << "\n\nSum of LOCs: " << @@sumOfLOCs << "\n"
      @@statsFile.close
      @@statsFile = nil
    end

    def SourceStats.appendInformation(string)
      @@statsFile << string if @@statsFile
    end

    @@fileHash = Hash.new

    def SourceStats.appendFiles(fileCollection)
      fileCollection.each do |fileName|
        @@fileHash[fileName] = nil # dummy value
      end
    end

    def SourceStats.hasFileName?(fileName)
      @@fileHash.has_key?(fileName)
    end

    @@sumOfLOCs = 0

    def SourceStats.increaseSumOfLOCs(amount)
      @@sumOfLOCs += amount
    end

  end



  # we modifiy several central classes to be as simple to use as possible (but its intrusive liek this of course)



  class Build  # modify class from main Makr module

    alias :originalBuildAliasedBySourceStatsExtension :build

    def build(task = nil)
      fileName = @buildPath + "/SourceStats.txt"
      SourceStats.createStatsFile(fileName)
      originalBuildAliasedBySourceStatsExtension(task)
      SourceStats.closeStatsFile()
    end
  end






  class FileCollector  # modify class from main Makr module

  protected

    class << self # need this construction to replace class method (need to be in singleton class to make the alias)
      alias :originalPrivateCollectAliasedBySourceStatsExtension :privateCollect
    end

    def FileCollector.privateCollect(dirName, pattern, exclusionPattern, fileCollection, recurse)
      originalPrivateCollectAliasedBySourceStatsExtension(dirName, pattern, exclusionPattern, fileCollection, recurse)
      SourceStats.appendFiles(fileCollection)
    end

  end






  class FileTask  # modify class from main Makr module

    alias :originalUpdateAliasedBySourceStatsExtension :update

    def update()
      originalUpdateAliasedBySourceStatsExtension()
      return if not SourceStats.hasFileName?(@fileName)
      sourceLines = IO.readlines(@fileName)
      @locCount = 0
      sourceLines.each do |line|
        @locCount += 1 if not line.strip.empty?
      end
      SourceStats.appendInformation(@fileName + ": LOC " + @locCount.to_s + "\n")
      SourceStats.increaseSumOfLOCs(@locCount)
    end
  end





end # end of module Makr



