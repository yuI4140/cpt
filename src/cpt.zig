const std = @import("std");
const nob = @cImport({  @cInclude("nob.h"); });
const Arena=std.heap.ArenaAllocator;
const c =@cImport({
  @cInclude("stdio.h");
  @cInclude("stdint.h");
  @cInclude("limits.h");
  @cInclude("stdlib.h");
  @cInclude("string.h");
});
fn get_type(path: []u8) ?std.fs.File.Kind
{
   var cwd= std.fs.cwd();
   var stat:?std.fs.File.Stat=undefined;
   stat = cwd.statFile(path) catch null;
   if (stat) |s| {
      return s.kind;
   }
   return null;
}
const CpTupleFile = struct {
    const Self=@This();
    alloc:std.mem.Allocator,
    path1:CpFile,
    path2:CpFile,
    dir  :std.fs.Dir,
    fn init(alloc:std.mem.Allocator,path1:[]u8,path2:[]u8) !Self
    {
        const p1=try CpFile.init(alloc,path1);
        const p2=try CpFile.init(alloc,path2);
        return .{
            .alloc = alloc ,
            .path1=p1,
            .path2=p2,
            .dir=p1.dir,
        };
    }
};
const CpFile = struct {
    const Self = @This();
    const CpFileKind = std.fs.File.Kind;
    dir  :std.fs.Dir,
    alloc: std.mem.Allocator,
    path : []u8,
    kind : ?CpFileKind,
    temp : ?[]u8 = null,
    fn get_basename_t(self: *Self) void
    {
        const basename = std.fs.path.basename(self.path);
        self.temp = self.alloc.dupe(u8, basename) catch null;
    }
    fn get_basename(self: Self) []u8
    {
        return @constCast(std.fs.path.basename(self.path));
    }
    fn temp_to_path(self: *Self) void
    {
        if (self.temp) |temp_str| {
            self.path = self.alloc.dupe(u8, temp_str) catch self.path;
        }
    }
    fn export_to(self: Self) ![]u8
    {
        var ex=try self.alloc.alloc(u8,256);
        _=c.memset(ex.ptr,0,256);
        _=c.memcpy(ex.ptr,self.path.ptr,self.path.len);
        ex.len=self.path.len;
        return ex;
    }
    fn init(alloc: std.mem.Allocator, path: []u8) !Self
    {
        const resolved_path = std.fs.cwd().realpathAlloc(alloc,path) catch path;
        const bufpath=try alloc.dupe(u8,resolved_path);
        const kind= get_type(resolved_path);
        return Self{
            .alloc = alloc,
            .kind = kind,
            .path = bufpath,
            .temp = null,
            .dir  = std.fs.cwd(),
        };
    }
    fn deinit(self: *Self) void
    {
        self.alloc.free(self.path);
        if (self.temp) |temp_str| {
            self.alloc.free(temp_str);
        }
    }
};
const Cp = struct {
   const Self=@This();
   const CpResult = error {
       NotImplementedCpSrcDir,
   };
   alloc   : std.mem.Allocator,
   dest    :  CpFile,
   src     : CpFile,
   progress:u32,
   dir     :std.fs.Dir,
   npath   :[]u8,
   cpfiles :std.ArrayList(CpFile),
   cps     :std.ArrayList(Cp),
   threads :std.ArrayList(std.Thread),
   subdirs  :std.ArrayList([]u8),
   fn init(cptfile:CpTupleFile) !Self {
       const files=try std.ArrayList(CpFile).initCapacity(cptfile.alloc,1024);
       const subdirs=try std.ArrayList([]u8).initCapacity(cptfile.alloc,1024);
       const cps  =try std.ArrayList(Cp)
       .initCapacity(cptfile.alloc,files.items.len*std.fs.max_path_bytes);
       const threads  = try std.ArrayList(std.Thread)
       .initCapacity(cptfile.alloc,files.items.len*std.fs.max_path_bytes);
       return .{
           .alloc   =cptfile.alloc,
           .dest    =cptfile.path2,
           .src     =cptfile.path1,
           .npath   =undefined,
           .progress=0,
           .dir=cptfile.dir,
           .cpfiles=files,
           .cps=cps,
           .threads=threads,
           .subdirs =subdirs,
       };
   }
   fn collect_from_dir(self: *Self, path: []u8) !bool {
       var file_paths:nob.Nob_File_Paths=std.mem.zeroes(nob.Nob_File_Paths);
       const cpath=try self.alloc.dupeZ(u8,path);
       if (!nob.nob_read_entire_dir(cpath,&file_paths)) {
           return false;
       }
       for(0..file_paths.count) |i| {
           const e = file_paths.items[i];
           if ((c.strcmp(".",e))==0 or (c.strcmp("..",e))==0  ) continue;
           var npath = try self.alloc.alloc(u8,std.fs.max_path_bytes);
           _=c.memset(npath.ptr,0,std.fs.max_path_bytes);
           npath.len=@intCast(c.snprintf(npath.ptr,std.fs.max_path_bytes,"%s/%s",cpath.ptr,e));
           const cpfile = try CpFile.init(self.alloc, npath);
           if (cpfile.kind) |k| {
            if (k == .directory) {
                const dirpath=std.fs.path.stem(cpfile.path);
                try self.subdirs.append(self.alloc,@constCast(dirpath));
                if(!try self.collect_from_dir(npath)){
                    return false;
                }
            } else {
                try self.cpfiles.append(self.alloc,cpfile);
            }
           }
       }
       return true;
   }
   fn collect_npath (self:*Self) !void {
      var npath=try self.alloc.alloc(u8,256);
      _=c.memset(npath.ptr,0,256);
      if (self.src.kind) |k| {
        if (k==.directory) {
            if(!try self.collect_from_dir(self.src.path)){
                return;
            }
            const dirpath=std.fs.path.stem(self.src.path);
            const destdir=try std.fmt.allocPrint(self.alloc,
            "{s}/{s}",  .{
                self.dest.path,
                dirpath
            });
            if (!nob.nob_mkdir_if_not_exists(destdir.ptr)) {
            return;
            }
            std.debug.print("Creating Subdirs on {s}\n", .{destdir});
            for (self.subdirs.items) |subdir_r| {
                const subdir_abs=try std.fmt.allocPrint(self.alloc,
                "{s}/{s}",  .{
                    destdir,
                    subdir_r
                });
                if (!nob.nob_mkdir_if_not_exists(subdir_abs.ptr)) {
                    return;
                }
            }
            for (self.cpfiles.items) |e| {
                const e_dirpath =std.fs.path.dirname(e.path);
                const e_basepath=std.fs.path.basename(e.path);
                if (e_dirpath) |dirpathe| {
                    const dest=try std.fmt.allocPrint(self.alloc,
                    "{s}/{s}/{s}",  .{
                        destdir,
                        std.fs.path.stem(dirpathe),e_basepath
                    });
                    const cptf=try CpTupleFile.init(self.alloc,e.path,dest);
                    const cp  =try Cp.init(cptf);
                    try self.cps.append(self.alloc,cp);
                }
            }
        } else {
            const csrcbae=self.src.get_basename();
            const cdest=try self.dest.export_to();
            _=c.snprintf(npath.ptr,256,"%s/%s",cdest.ptr,csrcbae.ptr);
            npath.len=@intCast(c.strlen(npath.ptr));
            self.npath=npath;
        }
      }
   }
   fn copy_file(self:Self) u8 {
       const src:?[:0]u8=self.alloc.dupeZ(u8,self.src.path) catch null;
       const dest:?[:0]u8=self.alloc.dupeZ(u8,self.dest.path) catch null;
       if (src!=null and dest!=null){
           const s=src.?; const d=dest.?;
           if(!nob.nob_copy_file(s,d)){
               return 0;
           }
       }
       return 1;
   }
   fn copy(self:*Self) !bool  {
       if (self.src.kind) |k| {
        switch (k) {
            CpFile.CpFileKind.directory => {
                std.debug.print("Initializing Threads ( Threads Count {} )\n",.{self.cps.items.len});
                for (self.cps.items) |cp| {
                    const thread = try std.Thread. spawn(
                        .{ .allocator = self.alloc },
                        Cp.copy_file,.{cp}
                    );
                    try self.threads.append(self.alloc,thread);
                }
                for (self.threads.items) |thread| {
                    thread.join();
                }
            },
            CpFile.CpFileKind.file => {
                if(self.copy_file()!=1){
                    return false;
                }
                },
                else => {
                    unreachable;
                }
        }
       }
       return true;
   }
};
pub fn main() !void
{
    var arena_loc=Arena.init(std.heap.page_allocator);
    defer arena_loc.deinit();
    const alloc = arena_loc.allocator();
    var args = std.os.argv;
    const program = args[0];
    var buffer:[1024]u8=undefined;
    var outwriter = std.fs.File.stdout().writer(&buffer);
    var stdout = &outwriter.interface;
    args=args[1..];
    if (args.len!=2) {
        try stdout.print("Error: not enough arguments\n",.{});
        try stdout.print("Usage: {s} <src> <dest>\n",.{program});
        try stdout.flush();
        std.process.exit(1);
    }
    const src :[]u8 = args[0][0..std.mem.len(args[0])];
    const dest:[]u8 = args[1][0..std.mem.len(args[1])];
    const cptfile=CpTupleFile.init(alloc,src,dest) catch |err| {
        try stdout.print("SetPathCpTupleFile-Error: {}\n",.{err});
        return err;
    };
    const destc =try cptfile.path2.export_to();
    const srcc  =try cptfile.path1.export_to();
    try stdout.print("copying {s} -> {s}\n",.{srcc,destc});
    try stdout.flush();
    var cp=try Cp.init(cptfile);
    try cp.collect_npath();
    if (try cp.copy()) return;
}
