import XCTest
@testable import GhostMind

final class ContextDocumentTests: XCTestCase {
    
    func testParseSectionsSync() {
        let content = """
        # Section 1
        This is the content of section 1.
        It has multiple lines.
        
        # Section 2
        Content of section 2.
        
        ## Subsection
        Should be part of section 2 if we only look for H1, 
        OR it should be a new section if we look for any #.
        
        No heading here.
        """
        
        let sections = ContextDocument.parseSectionsSync(from: content)
        
        XCTAssertEqual(sections.count, 3, "Should have found 3 sections based on # or ## prefixes")
        XCTAssertEqual(sections[0].heading, "Section 1")
        XCTAssertTrue(sections[0].content.contains("multiple lines"))
        
        XCTAssertEqual(sections[1].heading, "Section 2")
        
        XCTAssertEqual(sections[2].heading, "Subsection")
        XCTAssertTrue(sections[2].content.contains("part of section 2"))
    }
    
    func testParseEmptyContent() {
        let sections = ContextDocument.parseSectionsSync(from: "")
        XCTAssertEqual(sections.count, 0)
    }
    
    func testParseHeadinglessContent() {
        let content = "Just some text without headings"
        let sections = ContextDocument.parseSectionsSync(from: content)
        XCTAssertEqual(sections.count, 0, "Headingless content should be ignored per specification")
    }
}
