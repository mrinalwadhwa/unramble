import Foundation

@testable import FreeFlowKit

// ---------------------------------------------------------------------------
// Shared test data for all polish scenario tests. Each scenario captures a
// realistic dictation input, one or more acceptable polished outputs, and
// an optional app context for context-aware formatting.
//
// Covers fillers, corrections, punctuation, numbers, lists, homophones,
// capitalization, wording preservation, and more.
// ---------------------------------------------------------------------------

// swiftlint:disable line_length

/// A single polish scenario with category, raw input, acceptable outputs, and context.
struct PolishScenario {
    let category: String
    let input: String
    let accepted: [String]
    let context: AppContext
    let stableCloud: Bool
    let stableLocal: Bool

    init(_ category: String, _ input: String, _ accepted: String...,
         context: AppContext = .empty, cloud: Bool = false, local: Bool = false) {
        self.category = category
        self.input = input
        self.accepted = accepted
        self.context = context
        self.stableCloud = cloud
        self.stableLocal = local
    }

    func matches(_ output: String) -> Bool {
        let normalize = { (s: String) in
            s.replacingOccurrences(of: "\u{2019}", with: "'")
             .replacingOccurrences(of: "\u{2018}", with: "'")
             .replacingOccurrences(of: "\u{201C}", with: "\"")
             .replacingOccurrences(of: "\u{201D}", with: "\"")
        }
        let normalizedOutput = normalize(output)
        return accepted.contains { normalize($0) == normalizedOutput }
    }
}

/// All unique polish scenarios across all test suites (~113 cases).
let allScenarios: [PolishScenario] = [

    // ── Filler ──

    PolishScenario("filler",
        "um so I was thinking we should um probably update the documentation",
        "I was thinking we should probably update the documentation."),
    PolishScenario("filler",
        "like I basically just need to uh figure out the API rate limits you know",
        "I just need to figure out the API rate limits.",
        "I need to figure out the API rate limits."),
    PolishScenario("filler",
        "so yeah I mean the deployment went fine right but we should still monitor it",
        "The deployment went fine, but we should still monitor it.",
        cloud: true),
    PolishScenario("filler",
        "it's like literally the most important thing we need to do",
        "It's the most important thing we need to do."),
    PolishScenario("filler",
        "well actually I think we should wait until Monday",
        "I think we should wait until Monday."),
    PolishScenario("filler",
        "okay so basically what happened was the server crashed at 3 AM",
        "The server crashed at 3 AM.",
        "The server crashed at 3 a.m."),
    PolishScenario("filler",
        "I just wanted to say that um we really need to uh prioritize this",
        "We really need to prioritize this."),
    PolishScenario("filler",
        "yeah no totally I agree with that approach",
        "I agree with that approach."),

    // ── Discourse ──

    PolishScenario("discourse",
        "so the thing is we need more budget for Q3",
        "We need more budget for Q3.",
        cloud: true),
    PolishScenario("discourse",
        "I mean at the end of the day it's about user experience",
        "At the end of the day, it's about user experience.",
        cloud: true),
    PolishScenario("discourse",
        "right so basically we should just ship it",
        "We should just ship it."),
    PolishScenario("discourse",
        "you see the problem is that we don't have enough test coverage",
        "The problem is that we don't have enough test coverage."),
    PolishScenario("discourse",
        "honestly I think the current design is fine",
        "Honestly, I think the current design is fine.",
        "I think the current design is fine.",
        cloud: true, local: true),

    // ── Thinking ──

    PolishScenario("thinking",
        "hmm I think the best approach would be to refactor first",
        "I think the best approach would be to refactor first."),
    PolishScenario("thinking",
        "mm let me think ah yes we should use the new API",
        "We should use the new API."),
    PolishScenario("thinking",
        "uh huh so the meeting is at 3",
        "The meeting is at 3.",
        local: true),
    PolishScenario("thinking",
        "mm hmm that makes sense let's go with plan B",
        "That makes sense. Let's go with plan B.",
        "That makes sense. Let's go with Plan B.",
        "That makes sense, let's go with plan B.",
        "That makes sense, let's go with Plan B."),
    PolishScenario("thinking",
        "ah right I forgot about that constraint",
        "I forgot about that constraint."),

    // ── Repetition ──

    PolishScenario("repetition",
        "I think I think we should fix the the login bug",
        "I think we should fix the login bug.",
        cloud: true, local: true),
    PolishScenario("repetition",
        "the problem is the problem is that we don't have enough test coverage",
        "The problem is that we don't have enough test coverage.",
        cloud: true, local: true),
    PolishScenario("repetition",
        "we need to we need to make sure that everything is backed up",
        "We need to make sure that everything is backed up.",
        "We need to make sure everything is backed up.",
        cloud: true, local: true),
    PolishScenario("repetition",
        "can you can you send me the report by Friday",
        "Can you send me the report by Friday?",
        cloud: true),
    PolishScenario("repetition",
        "it's it's really important that we that we get this right",
        "It's really important that we get this right.",
        cloud: true, local: true),

    // ── Correction ──

    PolishScenario("correction",
        "send the report to John no wait send it to Sarah instead",
        "Send the report to Sarah.",
        "Send the report to Sarah instead.",
        local: true),
    PolishScenario("correction",
        "the deadline is Friday I mean Monday the deadline is Monday",
        "The deadline is Monday.",
        cloud: true),
    PolishScenario("correction",
        "we should use Python actually let's use Rust for this",
        "Let's use Rust for this."),
    PolishScenario("correction",
        "the meeting is at 2 sorry 3 PM tomorrow",
        "The meeting is at 3 PM tomorrow.",
        "The meeting is at 3 p.m. tomorrow.",
        cloud: true),
    PolishScenario("correction",
        "let me rephrase the project will take two weeks not three",
        "The project will take two weeks, not three.",
        "The project will take 2 weeks, not 3."),
    PolishScenario("correction",
        "we have five hundred no wait five thousand active users",
        "We have 5,000 active users.",
        "We have 5000 active users.",
        cloud: true),
    PolishScenario("correction",
        "I'll book the flight for Tuesday actually make that Wednesday",
        "I'll book the flight for Wednesday."),
    PolishScenario("correction",
        "the budget is fifty thousand or rather sixty thousand dollars",
        "The budget is $60,000."),

    // ── Backtrack ──

    PolishScenario("backtrack",
        "the cost is two actually three hundred dollars per month",
        "The cost is $300 per month."),
    PolishScenario("backtrack",
        "I'll be there in ten no twenty minutes",
        "I'll be there in 20 minutes."),
    PolishScenario("backtrack",
        "we need three no four developers on this project",
        "We need 4 developers on this project."),

    // ── Punctuation ──

    PolishScenario("punctuation",
        "dear team comma I wanted to follow up on the project period",
        "Dear team, I wanted to follow up on the project.",
        cloud: true),
    PolishScenario("punctuation",
        "is this working question mark",
        "Is this working?",
        cloud: true),
    PolishScenario("punctuation",
        "that's great exclamation point",
        "That's great!",
        cloud: true, local: true),
    PolishScenario("punctuation",
        "the options are colon option A semicolon option B semicolon and option C",
        "The options are: option A; option B; and option C.",
        local: true),
    PolishScenario("punctuation",
        "he said open quote I'll be there close quote",
        "He said \u{201c}I'll be there.\u{201d}",
        "He said, \u{201c}I'll be there.\u{201d}",
        cloud: true, local: true),
    PolishScenario("punctuation",
        "check the function open paren user ID close paren",
        "Check the function (user ID).",
        "Check the function (userID).",
        local: true),
    PolishScenario("punctuation",
        "first paragraph new paragraph second paragraph",
        "First paragraph.\n\nSecond paragraph."),
    PolishScenario("punctuation",
        "add a note new line then add the details",
        "Add a note.\nThen add the details."),
    PolishScenario("punctuation",
        "wait dot dot dot I need to think about this",
        "Wait\u{2026} I need to think about this."),

    // ── Number ──

    PolishScenario("number",
        "the conversion rate is twenty three point five percent",
        "The conversion rate is 23.5%.",
        cloud: true),
    PolishScenario("number",
        "the budget is five hundred thousand dollars",
        "The budget is $500,000.",
        cloud: true, local: true),
    PolishScenario("number",
        "we have twelve million active users",
        "We have 12 million active users.",
        cloud: true),
    PolishScenario("number",
        "the temperature is minus forty degrees Celsius",
        "The temperature is -40\u{00b0}C."),
    PolishScenario("number",
        "my phone number is five five five one two three four five six seven",
        "My phone number is 555-123-4567."),
    PolishScenario("number",
        "the meeting is at two thirty PM on March fifteenth",
        "The meeting is at 2:30 PM on March 15th.",
        "The meeting is at 2:30 p.m. on March 15th.",
        cloud: true, local: true),
    PolishScenario("number",
        "version three point fourteen point one",
        "Version 3.14.1",
        "Version 3.14.1.",
        cloud: true),
    PolishScenario("number",
        "the ratio is one to four",
        "The ratio is 1:4."),
    PolishScenario("number",
        "it costs ninety nine dollars and ninety nine cents",
        "It costs $99.99.",
        "It costs $99.99"),

    // ── List ──

    PolishScenario("list",
        "the priorities are first fix the login bug second add caching third write documentation",
        "The priorities are:\n1. Fix the login bug\n2. Add caching\n3. Write documentation"),
    PolishScenario("list",
        "I need to buy eggs milk bread butter and cheese",
        "I need to buy:\n- Eggs\n- Milk\n- Bread\n- Butter\n- Cheese"),
    PolishScenario("list",
        "step one clone the repo step two install dependencies step three run tests step four deploy",
        "1. Clone the repo\n2. Install dependencies\n3. Run tests\n4. Deploy"),
    PolishScenario("list",
        "please order five monitors three keyboards and ten mice",
        "Please order:\n- 5 monitors\n- 3 keyboards\n- 10 mice"),
    PolishScenario("list",
        "the action items from the meeting are update the roadmap schedule a design review and hire two more engineers",
        "The action items from the meeting are:\n- Update the roadmap\n- Schedule a design review\n- Hire two more engineers",
        "The action items from the meeting are:\n- Update the roadmap\n- Schedule a design review\n- Hire 2 more engineers"),

    // ── Capitalization ──

    PolishScenario("capitalization",
        "i went to new york last week and met with john from google",
        "I went to New York last week and met with John from Google.",
        cloud: true, local: true),
    PolishScenario("capitalization",
        "we're using kubernetes on aws with a postgres database",
        "We're using Kubernetes on AWS with a Postgres database.",
        "We are using Kubernetes on AWS with a Postgres database.",
        "We're using Kubernetes on AWS with a PostgreSQL database.",
        "We are using Kubernetes on AWS with a PostgreSQL database."),
    PolishScenario("capitalization",
        "can you ask sarah from the london office about the api changes",
        "Can you ask Sarah from the London office about the API changes?",
        cloud: true),
    PolishScenario("capitalization",
        "the iphone sixteen pro max runs ios eighteen",
        "The iPhone 16 Pro Max runs iOS 18.",
        cloud: true, local: true),
    PolishScenario("capitalization",
        "microsoft teams doesn't work well with google chrome on macos",
        "Microsoft Teams doesn't work well with Google Chrome on macOS.",
        "Microsoft Teams doesn't work well with Google Chrome on MacOS.",
        cloud: true, local: true),

    // ── Run-on ──

    PolishScenario("run-on",
        "so the thing is we tried to deploy on Friday but the tests failed and then we had to roll back and then on Monday we fixed the issue and redeployed and it worked",
        "We tried to deploy on Friday, but the tests failed, so we had to roll back. On Monday, we fixed the issue and redeployed, and it worked.",
        "We tried to deploy on Friday, but the tests failed and we had to roll back. On Monday we fixed the issue and redeployed, and it worked.",
        "We tried to deploy on Friday but the tests failed. We had to roll back. On Monday we fixed the issue and redeployed, and it worked.",
        "We tried to deploy on Friday, but the tests failed. We had to roll back. On Monday, we fixed the issue and redeployed, and it worked."),
    PolishScenario("run-on",
        "I talked to the client and they want the feature by next week and also they asked about pricing and I told them we'd send a proposal",
        "I talked to the client. They want the feature by next week. They also asked about pricing, and I told them we'd send a proposal."),
    PolishScenario("run-on",
        "we need to update the database and then run the migrations and then restart the service and then verify that everything is working and then notify the team",
        "We need to update the database, run the migrations, and restart the service. Then verify that everything is working and notify the team."),

    // ── False Start ──

    PolishScenario("false-start",
        "I was going to say but never mind the point is we need more testing",
        "The point is we need more testing."),
    PolishScenario("false-start",
        "what if we no that won't work let's just use the existing approach",
        "Let's just use the existing approach."),
    PolishScenario("false-start",
        "maybe we could or actually no let's just go with the original plan",
        "Let's just go with the original plan."),
    PolishScenario("false-start",
        "I think we should try to hmm actually you know what let me come back to this later",
        "Let me come back to this later."),

    // ── Email ──

    PolishScenario("email",
        "hey can you um send me the thing we talked about yesterday like the report or whatever",
        "Hi, could you send me the report we discussed yesterday?",
        context: AppContext(bundleID: "com.apple.mail", appName: "Mail", windowTitle: "New Message")),
    PolishScenario("email",
        "thanks for getting back to me so I wanted to follow up on the proposal we sent last week",
        "Thanks for getting back to me. I wanted to follow up on the proposal we sent last week.",
        context: AppContext(bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Re: Proposal"),
        cloud: true),
    PolishScenario("email",
        "just circling back on this um are we still on track for the launch next Thursday",
        "Just circling back on this \u{2014} are we still on track for the launch next Thursday?",
        "Just circling back on this, are we still on track for the launch next Thursday?",
        context: AppContext(bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Re: Launch")),

    // ── Slack ──

    PolishScenario("slack",
        "yeah looks good to me let's ship it",
        "yeah looks good to me, let's ship it",
        context: AppContext(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "#engineering")),
    PolishScenario("slack",
        "haha nice one okay I'll review it after lunch",
        "haha nice one, okay I'll review it after lunch",
        context: AppContext(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "#random")),
    PolishScenario("slack",
        "lgtm merge it",
        "lgtm, merge it",
        context: AppContext(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "#code-review")),

    // ── Code ──

    PolishScenario("code",
        "define a function called get user by ID that takes a user ID parameter",
        "Define a function called getUserById that takes a userId parameter.",
        context: AppContext(bundleID: "com.microsoft.VSCode", appName: "VS Code", windowTitle: "app.ts")),
    PolishScenario("code",
        "the variable should be named max retry count in snake case",
        "The variable should be named max_retry_count."),
    PolishScenario("code",
        "add a comment that says TODO fix this before release",
        "// TODO: Fix this before release",
        context: AppContext(bundleID: "com.microsoft.VSCode", appName: "VS Code", windowTitle: "main.swift")),
    PolishScenario("code",
        "import react from react and import use state from react",
        "import React from 'react'; import useState from 'react';",
        context: AppContext(bundleID: "com.microsoft.VSCode", appName: "VS Code", windowTitle: "App.jsx")),
    PolishScenario("code",
        "create a constant called API base URL equals https colon forward slash forward slash api dot example dot com",
        "const API_BASE_URL = 'https://api.example.com'",
        context: AppContext(bundleID: "com.microsoft.VSCode", appName: "VS Code", windowTitle: "config.ts")),

    // ── Homophone ──

    PolishScenario("homophone",
        "I need to by some groceries",
        "I need to buy some groceries.",
        cloud: true, local: true),
    PolishScenario("homophone",
        "I'll send it to you're email",
        "I'll send it to your email.",
        cloud: true),
    PolishScenario("homophone",
        "their going to be late for the meeting",
        "They're going to be late for the meeting.",
        "They are going to be late for the meeting.",
        "They\u{2019}re going to be late for the meeting.",
        cloud: true),
    PolishScenario("homophone",
        "the affect on performance was significant",
        "The effect on performance was significant.",
        cloud: true),
    PolishScenario("homophone",
        "we need to ensure the data is compliant with there policies",
        "We need to ensure the data is compliant with their policies.",
        cloud: true, local: true),
    PolishScenario("homophone",
        "its important that it's configuration is correct",
        "It's important that its configuration is correct.",
        "It is important that its configuration is correct.",
        "It\u{2019}s important that its configuration is correct.",
        cloud: true),

    // ── Apple Bug ──

    PolishScenario("apple-bug",
        "I will be there at 3, PM,, tomorrow,",
        "I will be there at 3 PM tomorrow.",
        "I will be there at 3 p.m. tomorrow.",
        "I will be there at 3:00 PM tomorrow.",
        cloud: true, local: true),
    PolishScenario("apple-bug",
        "the report is due due on Friday",
        "The report is due on Friday.",
        cloud: true),
    PolishScenario("apple-bug",
        "Let me know if you have any, questions, about the, project.",
        "Let me know if you have any questions about the project.",
        cloud: true),

    // ── URL ──

    PolishScenario("url",
        "check out our website at www dot example dot com",
        "Check out our website at www.example.com.",
        local: true),
    PolishScenario("url",
        "send it to john at example dot com",
        "Send it to john@example.com.",
        "Send it to john@example.com"),
    PolishScenario("url",
        "the API endpoint is slash API slash v2 slash users",
        "The API endpoint is /api/v2/users.",
        cloud: true),

    // ── Vocab ──

    PolishScenario("vocab",
        "we're deploying the kubernetes cluster on GKE with istio service mesh",
        "We're deploying the Kubernetes cluster on GKE with Istio service mesh.",
        cloud: true, local: true),
    PolishScenario("vocab",
        "the bug was reported by priya from the bangalore team",
        "The bug was reported by Priya from the Bangalore team.",
        cloud: true, local: true),
    PolishScenario("vocab",
        "use the fetch API with the authorization header set to bearer token",
        "Use the Fetch API with the Authorization header set to Bearer token."),

    // ── Preserve ──

    PolishScenario("preserve",
        "I wanted to grab some coffee before the meeting.",
        "I wanted to grab some coffee before the meeting.",
        cloud: true, local: true),
    PolishScenario("preserve",
        "I wanted to grab some coffee before the meeting",
        "I wanted to grab some coffee before the meeting.",
        cloud: true, local: true),
    PolishScenario("preserve",
        "He mentioned that the deadline might slip.",
        "He mentioned that the deadline might slip.",
        cloud: true, local: true),
    PolishScenario("preserve",
        "he mentioned that the deadline might slip",
        "He mentioned that the deadline might slip.",
        cloud: true, local: true),
    PolishScenario("preserve",
        "The thing is kinda broken.",
        "The thing is kinda broken.",
        cloud: true, local: true),
    PolishScenario("preserve",
        "the thing is kinda broken",
        "The thing is kinda broken.",
        local: true),
    PolishScenario("preserve",
        "I reckon we should ship it by Friday",
        "I reckon we should ship it by Friday.",
        cloud: true, local: true),

    // ── Clean ──

    PolishScenario("clean",
        "The deployment went smoothly.",
        "The deployment went smoothly.",
        cloud: true, local: true),
    PolishScenario("clean",
        "Can you review the pull request by end of day?",
        "Can you review the pull request by end of day?",
        cloud: true),
    PolishScenario("clean",
        "I'll be in the office from 9 AM to 5 PM.",
        "I'll be in the office from 9 AM to 5 PM.",
        cloud: true, local: true),
    PolishScenario("clean",
        "The meeting is scheduled for March 15th at 2:30 PM.",
        "The meeting is scheduled for March 15th at 2:30 PM.",
        "The meeting is scheduled for March 15th at 2:30 p.m.",
        cloud: true, local: true),

    // ── Multilingual ──

    PolishScenario("multilingual",
        "we should use the raison d'etre of the project as our north star",
        "We should use the raison d'\u{00ea}tre of the project as our north star.",
        "We should use the raison d'\u{00ea}tre of the project as our North Star.",
        local: true),
    PolishScenario("multilingual",
        "the restaurant is called cafe del sol on fifth avenue",
        "The restaurant is called Caf\u{00e9} del Sol on Fifth Avenue.",
        "The restaurant is called Cafe del Sol on Fifth Avenue.",
        cloud: true),
    PolishScenario("multilingual",
        "abhi meeting mein discuss karte hain then we'll send the proposal",
        "\u{0905}\u{092d}\u{0940} meeting \u{092e}\u{0947}\u{0902} discuss \u{0915}\u{0930}\u{0924}\u{0947} \u{0939}\u{0948}\u{0902}, then we'll send the proposal."),

    // ── Emphasis ──

    PolishScenario("emphasis",
        "this is really really important please don't forget",
        "This is really really important. Please don't forget.",
        "This is really important. Please don't forget.",
        "This is really important \u{2014} please don't forget.",
        "This is really really important, please don't forget.",
        cloud: true),
    PolishScenario("emphasis",
        "no no no that's completely wrong we need to start over",
        "No, no, no, that's completely wrong. We need to start over.",
        "No, no, no. That's completely wrong. We need to start over.",
        "No no no, that's completely wrong. We need to start over."),

    // ── Meeting ──

    PolishScenario("meeting",
        "okay so in today's standup um john said the backend API is ready sarah mentioned she's blocked on the design review and mike said he'll finish the tests by tomorrow",
        "In today's standup:\n- John said the backend API is ready.\n- Sarah mentioned she's blocked on the design review.\n- Mike said he'll finish the tests by tomorrow."),
    PolishScenario("meeting",
        "the key takeaways from the meeting are one we need to hire two more engineers two the deadline is moved to April fifteenth and three we should schedule a follow up for next week",
        "The key takeaways from the meeting are:\n1. We need to hire 2 more engineers.\n2. The deadline is moved to April 15th.\n3. We should schedule a follow-up for next week."),
    // ── Keep Tags (tests polish prompt preserving <keep>-wrapped symbols) ──

    PolishScenario("keep-tag",
        "research ampersand development is our focus",
        "Research & development is our focus."),
    PolishScenario("keep-tag",
        "I was thinking dot dot dot maybe we should wait",
        "I was thinking\u{2026} maybe we should wait.",
        "I was thinking \u{2026} maybe we should wait."),
    PolishScenario("keep-tag",
        "check the hashtag trending topic",
        "Check the #trending topic."),
    PolishScenario("keep-tag",
        "two plus sign three equals sign five",
        "2 + 3 = 5.",
        "2+3=5.",
        "2 + 3 = 5"),
    PolishScenario("keep-tag",
        "the price is dollar sign fifty with a ten percent sign discount",
        "The price is $50 with a 10% discount."),
    PolishScenario("keep-tag",
        "use asterisk bold asterisk for formatting",
        "Use *bold* for formatting."),
    PolishScenario("keep-tag",
        "first part new paragraph second part",
        "First part.\n\nSecond part."),
    PolishScenario("keep-tag",
        "see the summary new line details are below",
        "See the summary.\nDetails are below."),

    // ── Two-item Lists (should stay inline, not become vertical) ──

    PolishScenario("two-item-list",
        "I need to buy eggs and milk",
        "I need to buy eggs and milk.",
        cloud: true, local: true),
    PolishScenario("two-item-list",
        "the options are upgrade or replace",
        "The options are upgrade or replace.",
        "The options are: upgrade or replace.",
        cloud: true, local: true),
    PolishScenario("two-item-list",
        "please review the design and the implementation",
        "Please review the design and the implementation.",
        cloud: true, local: true),

    // ── No Lead-in List (should not invent introductory text) ──

    PolishScenario("no-leadin-list",
        "eggs milk bread butter and cheese",
        "Eggs, milk, bread, butter, and cheese.",
        "- Eggs\n- Milk\n- Bread\n- Butter\n- Cheese"),
    PolishScenario("no-leadin-list",
        "first update the docs second run the tests third deploy",
        "1. Update the docs\n2. Run the tests\n3. Deploy"),

    // ── Contraction Preservation ──

    PolishScenario("contraction",
        "I'll send it tomorrow and we'll review it on Monday",
        "I'll send it tomorrow and we'll review it on Monday.",
        "I'll send it tomorrow, and we'll review it on Monday.",
        cloud: true),
    PolishScenario("contraction",
        "we're planning to launch and it's going to be great",
        "We're planning to launch, and it's going to be great.",
        "We're planning to launch and it's going to be great.",
        cloud: true, local: true),
    PolishScenario("contraction",
        "they've already finished and we've just started",
        "They've already finished, and we've just started.",
        "They've already finished and we've just started.",
        cloud: true, local: true),
    PolishScenario("contraction",
        "I can't believe it doesn't work",
        "I can't believe it doesn't work.",
        cloud: true),

    // ── Small Numbers (prompt says convert ALL numbers to digits) ──

    PolishScenario("small-number",
        "we need three developers on this",
        "We need 3 developers on this.",
        cloud: true),
    PolishScenario("small-number",
        "there are two options here",
        "There are 2 options here."),
    PolishScenario("small-number",
        "I have eight files to review",
        "I have 8 files to review.",
        cloud: true),
    PolishScenario("small-number",
        "it took about thirty seconds to load",
        "It took about 30 seconds to load.",
        cloud: true),
    PolishScenario("small-number",
        "we only have one server left",
        "We only have 1 server left."),

    // ── Ordinal Numbers ──

    PolishScenario("ordinal",
        "the meeting is on the third floor",
        "The meeting is on the 3rd floor.",
        cloud: true),
    PolishScenario("ordinal",
        "she's the twenty first employee",
        "She's the 21st employee.",
        cloud: true, local: true),
    PolishScenario("ordinal",
        "this is our fifth release this year",
        "This is our 5th release this year.",
        cloud: true),

    // ═══════════════════════════════════════════════════════════════════
    // Additional scenarios — broadening coverage of stable categories
    // ═══════════════════════════════════════════════════════════════════

    // ── Clean ──

    PolishScenario("clean",
        "The server responded with a 200 status code.",
        "The server responded with a 200 status code."),
    PolishScenario("clean",
        "We shipped the hotfix yesterday afternoon.",
        "We shipped the hotfix yesterday afternoon."),
    PolishScenario("clean",
        "Please forward the invoice to the finance team.",
        "Please forward the invoice to the finance team."),

    // ── Preserve ──

    PolishScenario("preserve",
        "She's gonna present the demo tomorrow.",
        "She's gonna present the demo tomorrow."),
    PolishScenario("preserve",
        "she's gonna present the demo tomorrow",
        "She's gonna present the demo tomorrow."),
    PolishScenario("preserve",
        "We gotta finish this before the deadline.",
        "We gotta finish this before the deadline."),

    // ── Contraction ──

    PolishScenario("contraction",
        "she's already left and I haven't finished yet",
        "She's already left, and I haven't finished yet.",
        "She's already left and I haven't finished yet."),
    PolishScenario("contraction",
        "he won't agree but she'll probably support it",
        "He won't agree, but she'll probably support it.",
        "He won't agree but she'll probably support it."),
    PolishScenario("contraction",
        "I shouldn't have waited and now we're behind",
        "I shouldn't have waited, and now we're behind.",
        "I shouldn't have waited and now we're behind."),
    PolishScenario("contraction",
        "you'd think it'd be simpler but it isn't",
        "You'd think it'd be simpler, but it isn't.",
        "You'd think it'd be simpler but it isn't."),

    // ── Repetition ──

    PolishScenario("repetition",
        "we should we should update the the documentation",
        "We should update the documentation."),
    PolishScenario("repetition",
        "the the client wants wants a progress report",
        "The client wants a progress report."),
    PolishScenario("repetition",
        "please please send me the the latest build",
        "Please send me the latest build."),
    PolishScenario("repetition",
        "she said she said the timeline is is too aggressive",
        "She said the timeline is too aggressive."),

    // ── Homophone ──

    PolishScenario("homophone",
        "we need to check weather the server is running",
        "We need to check whether the server is running."),
    PolishScenario("homophone",
        "the team has too many tasks and not enough personal",
        "The team has too many tasks and not enough personnel."),
    PolishScenario("homophone",
        "please bare with me while I pull up the report",
        "Please bear with me while I pull up the report."),
    PolishScenario("homophone",
        "who's laptop is on the conference table",
        "Whose laptop is on the conference table?"),

    // ── Apple Bug ──

    PolishScenario("apple-bug",
        "The meeting is at, 10,, AM, on Monday,",
        "The meeting is at 10 AM on Monday."),
    PolishScenario("apple-bug",
        "Please, send, the report,, by Friday.",
        "Please send the report by Friday."),
    PolishScenario("apple-bug",
        "Can you check, the, status of, the deployment,,",
        "Can you check the status of the deployment?",
        "Can you check the status of the deployment."),

    // ── Capitalization ──

    PolishScenario("capitalization",
        "we scheduled a meeting with alex from amazon in seattle",
        "We scheduled a meeting with Alex from Amazon in Seattle."),
    PolishScenario("capitalization",
        "the android app uses firebase and kotlin",
        "The Android app uses Firebase and Kotlin."),
    PolishScenario("capitalization",
        "jennifer from the paris office joined the zoom call",
        "Jennifer from the Paris office joined the Zoom call."),

    // ── Punctuation ──

    PolishScenario("punctuation",
        "sure thing exclamation point I'll handle it",
        "Sure thing! I'll handle it."),
    PolishScenario("punctuation",
        "dear hiring manager comma I am writing to apply for the position period",
        "Dear hiring manager, I am writing to apply for the position."),
    PolishScenario("punctuation",
        "can we push the launch question mark I need more time",
        "Can we push the launch? I need more time."),
    PolishScenario("punctuation",
        "she asked open quote when is the deadline close quote",
        "She asked \u{201c}When is the deadline?\u{201d}",
        "She asked, \u{201c}When is the deadline?\u{201d}",
        "She asked, \u{201c}when is the deadline?\u{201d}"),

    // ── Discourse ──

    PolishScenario("discourse",
        "look the bottom line is we need more time",
        "The bottom line is we need more time.",
        "We need more time."),
    PolishScenario("discourse",
        "frankly the current approach isn't working",
        "Frankly, the current approach isn't working.",
        "The current approach isn't working."),
    PolishScenario("discourse",
        "to be honest I don't think this will ship on time",
        "To be honest, I don't think this will ship on time.",
        "I don't think this will ship on time."),
    PolishScenario("discourse",
        "at the end of the day we just need it to work",
        "At the end of the day, we just need it to work.",
        "At the end of the day we just need it to work.",
        "We just need it to work."),

    // ── Thinking ──

    PolishScenario("thinking",
        "hmm let me see I think we need a bigger instance",
        "I think we need a bigger instance.",
        "We need a bigger instance."),
    PolishScenario("thinking",
        "uh let me think okay yes the config file is wrong",
        "The config file is wrong."),
    PolishScenario("thinking",
        "ah okay so the cache expires every hour",
        "The cache expires every hour."),
    PolishScenario("thinking",
        "mm right the error only happens in production",
        "The error only happens in production."),

    // ── Emphasis ──

    PolishScenario("emphasis",
        "this is absolutely absolutely critical for the launch",
        "This is absolutely critical for the launch."),
    PolishScenario("emphasis",
        "please please please don't merge that branch",
        "Please, please, please don't merge that branch.",
        "Please please please don't merge that branch.",
        "Please please please, don't merge that branch."),
    PolishScenario("emphasis",
        "we must must fix this before release",
        "We must fix this before release."),
    PolishScenario("emphasis",
        "never ever deploy on a Friday afternoon",
        "Never ever deploy on a Friday afternoon.",
        "Never deploy on a Friday afternoon."),

    // ── Correction ──

    PolishScenario("correction",
        "email it to marketing I mean engineering",
        "Email it to engineering."),
    PolishScenario("correction",
        "the server runs Ubuntu sorry CentOS",
        "The server runs CentOS."),
    PolishScenario("correction",
        "we need five actually seven more licenses",
        "We need 7 more licenses."),
    PolishScenario("correction",
        "schedule it for Thursday no wait Friday morning",
        "Schedule it for Friday morning."),

    // ── Number ──

    PolishScenario("number",
        "the latency is about two hundred and fifty milliseconds",
        "The latency is about 250 milliseconds.",
        "The latency is about 250ms."),
    PolishScenario("number",
        "we processed one point two million requests yesterday",
        "We processed 1.2 million requests yesterday."),
    PolishScenario("number",
        "the disk is eighty five percent full",
        "The disk is 85% full."),
    PolishScenario("number",
        "the salary range is ninety thousand to one hundred twenty thousand dollars",
        "The salary range is $90,000 to $120,000."),

    // ── Vocab ──

    PolishScenario("vocab",
        "we migrated from jenkins to github actions last quarter",
        "We migrated from Jenkins to GitHub Actions last quarter."),
    PolishScenario("vocab",
        "the terraform config deploys to us east one on aws",
        "The Terraform config deploys to us-east-1 on AWS.",
        "The Terraform config deploys to US East 1 on AWS."),
    PolishScenario("vocab",
        "dmitri from the zurich office fixed the elasticsearch cluster",
        "Dmitri from the Zurich office fixed the Elasticsearch cluster."),
    PolishScenario("vocab",
        "we're switching from redis to memcached for session storage",
        "We're switching from Redis to Memcached for session storage."),

    // ── Two-Item List ──

    PolishScenario("two-item-list",
        "the choices are accept or reject",
        "The choices are accept or reject.",
        "The choices are: accept or reject."),
    PolishScenario("two-item-list",
        "we need to test the frontend and the backend",
        "We need to test the frontend and the backend."),
    PolishScenario("two-item-list",
        "I talked to the designer and the product manager",
        "I talked to the designer and the product manager."),
    PolishScenario("two-item-list",
        "you can use SSH or the web console",
        "You can use SSH or the web console."),
]

/// Scenarios that pass every cloud run.
let stableCloudScenarios = allScenarios.filter { $0.stableCloud }

/// Scenarios that pass every local run.
let stableLocalScenarios = allScenarios.filter { $0.stableLocal }

/// Scenarios that pass every run on both cloud and local.
let stableBothScenarios = allScenarios.filter { $0.stableCloud && $0.stableLocal }

// swiftlint:enable line_length
