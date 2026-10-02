// swift-tools-version: 6.0
import PackageDescription

let package=Package(name:"CosyVoice3iOS",platforms:[.iOS(.v17),.macOS(.v14)],products:[.library(name:"CosyVoice3Core",targets:["CosyVoice3Core"])],targets:[.target(name:"CosyVoice3Core",path:"Sources/CosyVoice3Core",linkerSettings:[.linkedFramework("CoreML")]),.testTarget(name:"CosyVoice3CoreTests",dependencies:["CosyVoice3Core"],path:"Tests/CosyVoice3CoreTests")])
