
module Makr



  # Convenience class related to Config adding compiler flags (Config key "compiler.cFlags") and
  # options related to a lib using pkg-config.
  class PkgConfig

    # cflags to config
    def self.addCFlags(config, pkgName)
      config.addUnique("compiler.cFlags", " " + (`pkg-config --cflags #{pkgName}`).strip!)
    end


    # add libs to config
    def self.addLibs(config, pkgName, static = false)
      command = "pkg-config --libs " + ((static)? " --static ":"") + pkgName
      config.addUnique("linker.lFlags", " " + (`#{command}`).strip!)
    end


    # add libs and cflags to config
    def self.add(config, pkgName)
      PkgConfig.addCFlags(config, pkgName)
      PkgConfig.addLibs(config, pkgName)
    end


    def self.getAllLibs()
      list = `pkg-config --list-all`
      hash = Hash.new
      list.each_line do |line|
        splitArr = line.split ' ', 2 # only split at the first space
        hash[splitArr.first] = splitArr.last
      end
      return hash
    end
  end



end

