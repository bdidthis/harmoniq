require "xcodeproj"
p = Xcodeproj::Project.open("Runner.xcodeproj")
t = p.targets.find{|x| x.name=="ShareExtension"}
if t
  t.remove_from_project
  r = p.targets.find{|x| x.name=="Runner"}
  if r
    r.build_phases.grep(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase).each do |ph|
      ph.files.delete_if{|f| f.file_ref && f.file_ref.path =~ /ShareExtension\.appex/}
    end
  end
  p.save
end
