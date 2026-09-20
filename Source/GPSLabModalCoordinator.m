//
//  GPSLabModalCoordinator.m
//  GPSLab
//
//  Serialized, session-scoped GPSLab-owned modal presentation. Every request is
//  evaluated on the main queue by GPSLabModalPolicy against live UIKit state;
//  at most one bounded request is queued. Completions only fire from a real
//  UIKit transition completion (never faked), stale work is invalidated by a
//  session generation, and the queue/transition/search rules live in the
//  portable policy.
//
//  Transition draining rules (no synchronous retry loops):
//   * tracked (GPSLab-initiated) transition: park and let our own present/dismiss
//     completion drain;
//   * untracked transition with a live transitionCoordinator: park and drain from
//     that coordinator's completion, on the next main-queue turn;
//   * untracked transition with no coordinator: drop the bounded request cleanly
//     (never retry on a nil coordinator).
//

#import "GPSLabModalCoordinator.h"

#include <string.h>

#import "GPSLabModalPolicy.h"
#import "GPSLabOverlayPresenter.h"
#import "GPSLabOverlayViewController.h"
#import "GPSLabSheetViewController.h"

@interface GPSLabModalCoordinator () {
    GPSLabModalSession _session;
}
@property (nonatomic, assign) BOOL transitioning;
@property (nonatomic, assign) BOOL searchDeferred;
@property (nonatomic, assign) BOOL waitingOnUntrackedTransition;
@property (nonatomic, assign) BOOL draining;
@property (nonatomic, copy, nullable) void (^pendingPresentation)(void);
@property (nonatomic, assign) unsigned long pendingGeneration;
@property (nonatomic, assign) NSUInteger transitionToken;
@end

@implementation GPSLabModalCoordinator

+ (instancetype)sharedCoordinator {
    static GPSLabModalCoordinator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabModalCoordinator alloc] init];
    });
    return instance;
}

#pragma mark - Main thread

- (void)gpslab_onMain:(dispatch_block_t)block {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

#pragma mark - Query

- (UIViewController *)topmostGPSLabViewController {
    UIViewController *controller = [GPSLabOverlayPresenter sharedPresenter].rootViewController;
    if (controller == nil) {
        return nil;
    }
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

- (BOOL)isPresentingModal {
    UIViewController *root = [GPSLabOverlayPresenter sharedPresenter].rootViewController;
    return root.presentedViewController != nil;
}

- (GPSLabOverlayViewController *)activeCanvas {
    UIViewController *root = [GPSLabOverlayPresenter sharedPresenter].rootViewController;
    if ([root isKindOfClass:[GPSLabOverlayViewController class]]) {
        return (GPSLabOverlayViewController *)root;
    }
    return nil;
}

/** Transition flags only (no coordinator); used for the untracked policy input. */
- (BOOL)anchorFlagsTransitioning:(UIViewController *)anchor {
    if (anchor == nil) {
        return NO;
    }
    if (anchor.isBeingPresented || anchor.isBeingDismissed) {
        return YES;
    }
    UIViewController *presented = anchor.presentedViewController;
    if (presented.isBeingPresented || presented.isBeingDismissed) {
        return YES;
    }
    return NO;
}

#pragma mark - Presentation

- (void)presentSheetRoot:(UIViewController *)root
              completion:(void (^)(void))completion {
    UINavigationController *navigation = GPSLabSheetNavigationController(root);
    if (navigation == nil) {
        return;
    }
    [self gpslab_present:navigation completion:completion];
}

- (void)presentAlert:(UIAlertController *)alert completion:(void (^)(void))completion {
    if (alert == nil) {
        return;
    }
    [self gpslab_present:alert completion:completion];
}

- (void)gpslab_present:(UIViewController *)controller completion:(void (^)(void))completion {
    [self gpslab_onMain:^{
        [self gpslab_evaluatePresentation:controller
                              completion:completion
                                generation:self->_session.generation];
    }];
}

- (void)gpslab_evaluatePresentation:(UIViewController *)controller
                         completion:(void (^)(void))completion
                           generation:(unsigned long)generation {
    if (!GPSLabModalSessionIsCurrent(&_session, generation)) {
        return; // stale request from a closed/replaced session
    }
    GPSLabOverlayPresenter *presenter = [GPSLabOverlayPresenter sharedPresenter];
    if (!presenter.isPresenting) {
        return;
    }
    UIViewController *anchor = [self topmostGPSLabViewController];
    GPSLabOverlayViewController *canvas = [self activeCanvas];

    BOOL ownTransition = self.transitioning;
    BOOL anchorFlags = [self anchorFlagsTransitioning:anchor];
    id<UIViewControllerTransitionCoordinator> coordinator = anchor.transitionCoordinator;

    GPSLabModalPolicyState state;
    memset(&state, 0, sizeof(state));
    state.session_valid = 1;
    state.anchor_present = (anchor != nil && anchor.view.window != nil) ? 1 : 0;
    state.search_session_active = (canvas != nil && canvas.isSearchSessionActive) ? 1 : 0;
    state.own_transition_active = ownTransition ? 1 : 0;
    state.untracked_transition_active = (!ownTransition && (anchorFlags || coordinator != nil)) ? 1 : 0;
    state.untracked_transition_hookable = (coordinator != nil) ? 1 : 0;
    state.anchor_is_root = (anchor != nil && anchor == presenter.rootViewController) ? 1 : 0;
    state.is_alert = [controller isKindOfClass:[UIAlertController class]] ? 1 : 0;
    state.pending_present = (self.pendingPresentation != nil) ? 1 : 0;

    GPSLabModalDecision decision = GPSLabModalPolicyDecidePresentation(&state);

    GPSLabModalCoordinator *__weak weakSelf = self;
    void (^park)(void) = ^{
        [weakSelf gpslab_evaluatePresentation:controller
                                  completion:completion
                                    generation:generation];
    };

    switch (decision) {
        case GPSLabModalDecisionDrop:
            return;
        case GPSLabModalDecisionDeferSearch:
            self.pendingGeneration = generation;
            self.pendingPresentation = park;
            self.searchDeferred = YES;
            [canvas endActiveSearch];
            return;
        case GPSLabModalDecisionParkForTrackedTransition:
            // Our own present/dismiss completion drains this; do not register an
            // untracked coordinator or retry.
            self.pendingGeneration = generation;
            self.pendingPresentation = park;
            return;
        case GPSLabModalDecisionWaitTransition:
            self.pendingGeneration = generation;
            self.pendingPresentation = park;
            [self registerUntrackedTransitionDrain:coordinator generation:generation];
            return;
        case GPSLabModalDecisionPresent:
            break;
    }

    [self presentNow:controller onAnchor:anchor completion:completion];
}

/**
 * Registers exactly one drain callback on an untracked transition coordinator.
 * The callback captures the request generation so an old callback can never
 * drain a newer session, and defers one main-queue turn because UIKit may still
 * be finishing the transition inside the same completion stack.
 */
- (void)registerUntrackedTransitionDrain:(id<UIViewControllerTransitionCoordinator>)coordinator
                              generation:(unsigned long)generation {
    if (coordinator == nil || self.waitingOnUntrackedTransition) {
        return;
    }
    self.waitingOnUntrackedTransition = YES;
    GPSLabModalCoordinator *__weak weakSelf = self;
    [coordinator animateAlongsideTransition:nil
                                 completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        GPSLabModalCoordinator *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf.waitingOnUntrackedTransition = NO;
        if (!GPSLabModalSessionIsCurrent(&strongSelf->_session, generation)) {
            return; // stale callback from a closed/replaced session
        }
        [strongSelf gpslab_onMain:^{
            [strongSelf drainPendingPresentationIfCurrent];
        }];
    }];
}

- (void)presentNow:(UIViewController *)controller
          onAnchor:(UIViewController *)anchor
        completion:(void (^)(void))completion {
    [[GPSLabOverlayPresenter sharedPresenter] acquireKeyLease];
    self.transitioning = YES;
    self.transitionToken += 1;
    NSUInteger token = self.transitionToken;

    GPSLabModalCoordinator *__weak weakSelf = self;
    [anchor presentViewController:controller
                         animated:YES
                       completion:^{
        GPSLabModalCoordinator *strongSelf = weakSelf;
        if (strongSelf == nil || token != strongSelf.transitionToken) {
            return;
        }
        strongSelf.transitioning = NO;
        if (completion != nil) {
            completion();
        }
        [strongSelf drainPendingPresentationIfCurrent];
    }];

    // UIKit updates presentedViewController synchronously. If the presentation
    // was refused, recover the busy flag and drop (never fake) the completion.
    if (anchor.presentedViewController != controller && !controller.isBeingPresented) {
        if (token == self.transitionToken) {
            self.transitionToken += 1; // invalidate the never-firing completion
            self.transitioning = NO;
            self.pendingPresentation = nil;
        }
    }
}

#pragma mark - Dismissal

- (void)dismissTopmostAnimated:(BOOL)animated completion:(void (^)(void))completion {
    [self gpslab_onMain:^{
        [self gpslab_evaluateDismissAnimated:animated
                                  completion:completion
                                    generation:self->_session.generation];
    }];
}

- (void)gpslab_evaluateDismissAnimated:(BOOL)animated
                            completion:(void (^)(void))completion
                              generation:(unsigned long)generation {
    if (!GPSLabModalSessionIsCurrent(&_session, generation)) {
        return; // stale; do not fake a completion
    }
    GPSLabOverlayPresenter *presenter = [GPSLabOverlayPresenter sharedPresenter];
    UIViewController *root = presenter.rootViewController;
    UIViewController *top = [self topmostGPSLabViewController];
    if (root == nil || top == nil || top == root) {
        if (completion != nil) {
            completion();
        }
        return;
    }
    if (self.transitioning || top.transitionCoordinator != nil ||
        [self anchorFlagsTransitioning:top]) {
        // A transition is already running. Drop rather than fake a completion or
        // stack a dismissal; the caller may request again once settled.
        return;
    }

    self.transitioning = YES;
    self.transitionToken += 1;
    NSUInteger token = self.transitionToken;
    GPSLabModalCoordinator *__weak weakSelf = self;
    [top dismissViewControllerAnimated:animated
                           completion:^{
        GPSLabModalCoordinator *strongSelf = weakSelf;
        if (strongSelf == nil || token != strongSelf.transitionToken) {
            return;
        }
        strongSelf.transitioning = NO;
        if (completion != nil) {
            completion();
        }
        [strongSelf drainPendingPresentationIfCurrent];
    }];
}

- (void)dismissAllAnimated:(BOOL)animated completion:(void (^)(void))completion {
    // UIKit dismisses the whole presented chain from the root in one call, so a
    // single dismissal is enough (no unbounded recursion).
    [self gpslab_onMain:^{
        UIViewController *root = [GPSLabOverlayPresenter sharedPresenter].rootViewController;
        if (root == nil || root.presentedViewController == nil) {
            if (completion != nil) {
                completion();
            }
            return;
        }
        if (self.transitioning || root.transitionCoordinator != nil ||
            [self anchorFlagsTransitioning:root]) {
            return; // drop; do not fake a completion
        }
        self.transitioning = YES;
        self.transitionToken += 1;
        NSUInteger token = self.transitionToken;
        GPSLabModalCoordinator *__weak weakSelf = self;
        [root dismissViewControllerAnimated:animated
                                 completion:^{
            GPSLabModalCoordinator *strongSelf = weakSelf;
            if (strongSelf == nil || token != strongSelf.transitionToken) {
                return;
            }
            strongSelf.transitioning = NO;
            if (completion != nil) {
                completion();
            }
            [strongSelf drainPendingPresentationIfCurrent];
        }];
    }];
}

#pragma mark - Pending work

/**
 * Non-reentrant, generation-checked drain. Clears the bounded pending before
 * running it so a re-evaluation that parks again forms a new pending rather than
 * recursing on the same one.
 */
- (void)drainPendingPresentationIfCurrent {
    if (self.draining) {
        return;
    }
    void (^pending)(void) = self.pendingPresentation;
    if (pending == nil) {
        return;
    }
    if (!GPSLabModalSessionIsCurrent(&_session, self.pendingGeneration)) {
        self.pendingPresentation = nil;
        return;
    }
    self.pendingPresentation = nil;
    self.draining = YES;
    pending();
    self.draining = NO;
}

- (void)clearPendingWork {
    self.pendingPresentation = nil;
    self.transitioning = NO;
    self.searchDeferred = NO;
    self.waitingOnUntrackedTransition = NO;
    self.transitionToken += 1;
}

#pragma mark - Session

- (void)resolvePendingPresentation {
    [self gpslab_onMain:^{
        self.searchDeferred = NO;
        [self drainPendingPresentationIfCurrent];
    }];
}

- (void)noteSessionOpened {
    [self gpslab_onMain:^{
        GPSLabModalSessionBegin(&self->_session);
        [self clearPendingWork];
    }];
}

- (void)noteSessionClosed {
    [self gpslab_onMain:^{
        GPSLabModalSessionEnd(&self->_session);
        [self clearPendingWork];
    }];
}

- (void)invalidateForRootReplacement {
    [self gpslab_onMain:^{
        GPSLabModalSessionInvalidate(&self->_session);
        [self clearPendingWork];
    }];
}

@end
