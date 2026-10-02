// CosyVoice3TextFrontend.swift
import Foundation
import Tokenizers
enum CosyVoice3TextFrontendError:Error { case tokenizer(String) }
struct CosyVoice3TextFrontend:Sendable {
 let tokenizer:any Tokenizer
 init(tokenizer:any Tokenizer){self.tokenizer=tokenizer}
 func textIDs(_ text:String)throws->[Int32]{let ids=tokenizer.encode(text:text);guard !ids.isEmpty,ids.allSatisfy({$0>=0&&$0<=Int(Int32.max)})else{throw CosyVoice3TextFrontendError.tokenizer("invalid Qwen token IDs")};return ids.map(Int32.init)}
 func instruct2Prompt(_ instruction:String?,referenceTranscript:String)throws->[Int32]{
  let trimmed=instruction?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
  let prompt=trimmed.isEmpty ? "You are a helpful assistant.<|endofprompt|>"+referenceTranscript : trimmed
  return try textIDs(prompt)
 }
}
// Purpose: native Qwen tokenizer and CosyVoice3 instruct2 prompt tokenization.
// Upstream: CosyVoice3Tokenizer/frontend_instruct2 at CosyVoice3_NPU@8789402.
// Runtime: swift-transformers Tokenizers1.3.4; tokenizer assets are distributed separately.
// Generated: 2026-10-02 America/New_York.
