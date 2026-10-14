import XCTest
@testable import SiriusCore

final class OnboardingTests: XCTestCase {
    func testShowsUntilCompletedAndWheneverNoAgentIsRegistered() {
        XCTAssertTrue(Onboarding.showsWindow(hasAgents: false, completed: false))
        XCTAssertTrue(Onboarding.showsWindow(hasAgents: false, completed: true))
        XCTAssertTrue(Onboarding.showsWindow(hasAgents: true, completed: false))
        XCTAssertFalse(Onboarding.showsWindow(hasAgents: true, completed: true))
    }

    func testFourPagesRunInOrder() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .agents, .permissions, .done])
        XCTAssertNil(OnboardingStep.welcome.previous)
        XCTAssertEqual(OnboardingStep.welcome.next, .agents)
        XCTAssertEqual(OnboardingStep.agents.previous, .welcome)
        XCTAssertEqual(OnboardingStep.agents.next, .permissions)
        XCTAssertEqual(OnboardingStep.permissions.next, .done)
        XCTAssertNil(OnboardingStep.done.next)
    }

    func testTheWelcomeHasNoDotAndTheStepsThree() {
        XCTAssertNil(OnboardingStep.welcome.dot)
        XCTAssertEqual(OnboardingStep.agents.dot, 0)
        XCTAssertEqual(OnboardingStep.permissions.dot, 1)
        XCTAssertEqual(OnboardingStep.done.dot, 2)
        XCTAssertEqual(OnboardingStep.dotted, [.agents, .permissions, .done])
    }

    func testOnlyTheAgentsStepHoldsContinue() {
        XCTAssertFalse(Onboarding.canContinue(from: .agents, agentsChosen: 0))
        XCTAssertTrue(Onboarding.canContinue(from: .agents, agentsChosen: 1))
        XCTAssertTrue(Onboarding.canContinue(from: .agents, agentsChosen: 2))
        for step in [OnboardingStep.welcome, .permissions, .done] {
            XCTAssertTrue(Onboarding.canContinue(from: step, agentsChosen: 0))
        }
    }

    func testTheFirstTurnTakesAMessageOnlyBeforeItIsSent() {
        XCTAssertTrue(FirstTurn.ready.takesMessage)
        XCTAssertTrue(FirstTurn.listening.takesMessage)
        XCTAssertFalse(FirstTurn.answering(transcript: "Hello", agent: "Claude").takesMessage)
        XCTAssertFalse(FirstTurn.composing.takesMessage)
    }

    func testTheReplyMovesTheAnswerOnToTheComposer() {
        XCTAssertEqual(FirstTurn.answering(transcript: "Hello", agent: "Claude").replied, .composing)
        // Nothing else moves on a reply: a toast before the first turn, or
        // a second one in D.
        for turn in [FirstTurn.ready, .listening, .composing] {
            XCTAssertEqual(turn.replied, turn)
        }
    }

    func testTheComposeRowComesBackInDAndHoldToTalkStaysDimmed() {
        XCTAssertEqual(FirstTurn.ready.holdRowOpacity, 1)
        XCTAssertEqual(FirstTurn.ready.composeRowOpacity, 1)
        for turn in [FirstTurn.listening, .answering(transcript: "Hello", agent: "Claude")] {
            XCTAssertEqual(turn.holdRowOpacity, 0.35)
            XCTAssertEqual(turn.composeRowOpacity, 0.35)
            XCTAssertFalse(turn.holdRowEnabled)
            XCTAssertFalse(turn.composeRowEnabled)
        }
        XCTAssertEqual(FirstTurn.composing.holdRowOpacity, 0.35)
        XCTAssertEqual(FirstTurn.composing.composeRowOpacity, 1)
        XCTAssertFalse(FirstTurn.composing.holdRowEnabled)
        XCTAssertTrue(FirstTurn.composing.composeRowEnabled)
    }

    func testTheWelcomeMovesOnAboutThreeSecondsAfterOpening() {
        XCTAssertEqual(WelcomeTiming.advance(reduceMotion: false), 3.15, accuracy: 0.001)
        // Reduce Motion fades rather than blurs in, and holds as long.
        XCTAssertEqual(WelcomeTiming.advance(reduceMotion: true) - WelcomeTiming.delay - WelcomeTiming.fade,
                       WelcomeTiming.hold, accuracy: 0.001)
    }
}
