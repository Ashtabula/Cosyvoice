// swift-tools-version: 6.0
import PackageDescription
let package = Package(
 name:"CosyVoice3iOS", platforms:[.iOS(.v18),.macOS(.v15)],
 products:[.library(name:"CosyVoice3Core",targets:["CosyVoice3Core"])],
 dependencies:[.package(url:"https://github.com/huggingface/swift-transformers.git",exact:"1.3.4")],
 targets:[
  .target(name:"CosyVoice3Core",dependencies:[.product(name:"Tokenizers",package:"swift-transformers")],path:"Sources/CosyVoice3Core",linkerSettings:[.linkedFramework("CoreML"),.linkedFramework("AVFoundation"),.linkedFramework("Accelerate")]),
  .testTarget(name:"CosyVoice3CoreTests",dependencies:["CosyVoice3Core",.product(name:"Tokenizers",package:"swift-transformers")],path:"Tests/CosyVoice3CoreTests")
 ])
