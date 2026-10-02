import XCTest
@testable import CosyVoice3Core

final class Stage1RuntimeTests:XCTestCase{
    func testExactPolicyHasZeroPadding()throws{let x=try CosyVoice3SequenceShapePolicy.exact(maximum:512).select(validLength:224);XCTAssertEqual(x,.init(validLength:224,physicalLength:224));XCTAssertEqual(x.paddingPositions,0)}
    func testStaticFallbackChoosesSmallestBucket()throws{let x=try CosyVoice3SequenceShapePolicy.staticBuckets([128,192,256,384]).select(validLength:224);XCTAssertEqual(x.physicalLength,256);XCTAssertEqual(x.paddingPositions,32)}
    func testDefaultDecodePolicyUsesTightSixteenTokenBucket()throws{let runtime=CosyVoice3Stage1Runtime();let x=try runtime.policy.llmDecodeCache.select(validLength:225);XCTAssertEqual(x.physicalLength,240);XCTAssertEqual(x.paddingPositions,15)}
    func testDefaultFlowPolicyUsesTightThirtyTwoFrameBucket()throws{let runtime=CosyVoice3Stage1Runtime();let x=try runtime.policy.flowFrames.select(validLength:752);XCTAssertEqual(x.physicalLength,768);XCTAssertEqual(x.paddingPositions,16)}
    func testOverflowFails(){XCTAssertThrowsError(try CosyVoice3SequenceShapePolicy.exact(maximum:512).select(validLength:513))}
    func testTensorPoolReusesArray()throws{let pool=CosyVoice3TensorPool(maximumArraysPerShape:1);let a=try pool.checkout(shape:[1,8]);pool.recycle(a);let b=try pool.checkout(shape:[1,8]);XCTAssertTrue(a===b)}
    func testMultifunctionSpecsHaveDifferentCacheKeys(){let url=URL(fileURLWithPath:"/tmp/llm.mlmodelc");let a=CosyVoice3ModelSpec(id:"llm",url:url,functionName:"prefill"),b=CosyVoice3ModelSpec(id:"llm",url:url,functionName:"decode");XCTAssertNotEqual(a.functionName,b.functionName)}
}
