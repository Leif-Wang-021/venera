Pod::Spec.new do |s|
  s.name             = 'zip_flutter'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter FFI plugin project.'
  s.description      = <<-DESC
A new Flutter FFI plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  s.library = 'c++'
  s.xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'CLANG_CXX_LIBRARY' => 'libc++',
  }
  
  s.pod_target_xcconfig = { 
    'DEFINES_MODULE' => 'YES', 
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_ENABLE_MODULES' => 'YES',
    'CLANG_ENABLE_OBJC_ARC' => 'YES',
    'OTHER_CPLUSPLUSFLAGS' => '-std=c++20 -stdlib=libc++',
    'OTHER_LDFLAGS' => '-stdlib=libc++',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'GCC_PREPROCESSOR_DEFINITIONS' => ['HAVE_PTHREADS=1']
  }
  
  s.swift_version = '5.0'
end