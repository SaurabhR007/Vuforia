/*===============================================================================
Copyright (c) 2016-2018 PTC Inc. All Rights Reserved.

Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.

Vuforia is a trademark of PTC Inc., registered in the United States and other 
countries.
===============================================================================*/

#import "CloudRecoViewController.h"
#import "VuforiaSamplesAppDelegate.h"
#import <Vuforia/Vuforia.h>
#import <Vuforia/TrackerManager.h>
#import <Vuforia/ObjectTracker.h>
#import <Vuforia/PositionalDeviceTracker.h>
#import <Vuforia/Trackable.h>
#import <Vuforia/ImageTarget.h>
#import <Vuforia/TargetFinder.h>
#import <Vuforia/CameraDevice.h>

#import "UnwindMenuSegue.h"
#import "PresentMenuSegue.h"
#import "SampleAppMenuViewController.h"

static const char* const kAccessKey = "7f0e89e71629c9504a8ebe5b5086d50bf7281e81";
static const char* const kSecretKey = "f164075a59d802f12caa27337399515af29ee007";


@interface CloudRecoViewController ()

@property (weak, nonatomic) IBOutlet UIImageView *ARViewPlaceholder;

@end

@implementation CloudRecoViewController

@synthesize tapGestureRecognizer, vapp, eaglView;


- (CGRect)getCurrentARViewFrame
{
    CGRect screenBounds = [[UIScreen mainScreen] bounds];
    return screenBounds;
}

- (BOOL) isVisualSearchOn {
    return isVisualSearchOn;
}

- (void) setVisualSearchOn:(BOOL) isOn {
    isVisualSearchOn = isOn;
}

- (void)loadView
{
    [super loadView];
    
    // Custom initialization
    self.title = @"Cloud Reco";
    
    if (self.ARViewPlaceholder != nil) {
        [self.ARViewPlaceholder removeFromSuperview];
        self.ARViewPlaceholder = nil;
    }
    
    scanningMode = YES;
    isVisualSearchOn = NO;
    resetTargetFinderTrackables = NO;
    
    deviceTrackerEnabled = NO;
    continuousAutofocusEnabled = YES;
    flashEnabled = NO;
    
    vapp = [[SampleApplicationSession alloc] initWithDelegate:self];
    
    CGRect viewFrame = [self getCurrentARViewFrame];
    
    eaglView = [[CloudRecoEAGLView alloc] initWithFrame:viewFrame appSession:vapp viewController:self];
    [eaglView setBackgroundColor:UIColor.clearColor];

    [self.view addSubview:eaglView];
    [self.view sendSubviewToBack:eaglView];
    
    VuforiaSamplesAppDelegate *appDelegate = (VuforiaSamplesAppDelegate*)[[UIApplication sharedApplication] delegate];
    appDelegate.glResourceHandler = eaglView;
    
    [self scanlineCreate];
    
    // double tap used to also trigger the menu
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget: self action:@selector(doubleTapGestureAction:)];
    doubleTap.numberOfTapsRequired = 2;
    [self.view addGestureRecognizer:doubleTap];
    
    // a single tap will trigger a single autofocus operation
    tapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(autofocus:)];
    if (doubleTap != NULL) {
        [tapGestureRecognizer requireGestureRecognizerToFail:doubleTap];
    }
    
    UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeGestureAction:)];
    [swipeRight setDirection:UISwipeGestureRecognizerDirectionRight];
    [self.view addGestureRecognizer:swipeRight];
    
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(dismissARViewController)
                                                 name:@"kDismissARViewController"
                                               object:nil];
    
    // we use the iOS notification to pause/resume the AR when the application goes (or come back from) background
    [[NSNotificationCenter defaultCenter]
     addObserver:self
     selector:@selector(pauseAR)
     name:UIApplicationWillResignActiveNotification
     object:nil];
    
    [[NSNotificationCenter defaultCenter]
     addObserver:self
     selector:@selector(resumeAR)
     name:UIApplicationDidBecomeActiveNotification
     object:nil];
    
    // initialize AR
    [vapp initAR:Vuforia::GL_20 orientation:[[UIApplication sharedApplication] statusBarOrientation] deviceMode:Vuforia::Device::MODE_AR stereo:false];

    // show loading animation while AR is being initialized
    [self showLoadingAnimation];
}

- (void) pauseAR {
    [self doStopTrackers];
    
    NSError * error = nil;
    if (![vapp pauseAR:&error]) {
        NSLog(@"Error pausing AR:%@", [error description]);
    }
}

- (void) resumeAR {
    [self doStartTrackers];
    
    NSError * error = nil;
    if(! [vapp resumeAR:&error]) {
        NSLog(@"Error resuming AR:%@", [error description]);
    }
    [eaglView updateRenderingPrimitives];
    // on resume, we reset the flash
    Vuforia::CameraDevice::getInstance().setFlashTorchMode(false);
    flashEnabled = NO;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.showingMenu = NO;
    
    // Do any additional setup after loading the view.
    [self.navigationController setNavigationBarHidden:YES animated:NO];
    [self.view addGestureRecognizer:tapGestureRecognizer];
    
    NSLog(@"self.navigationController.navigationBarHidden: %s", self.navigationController.navigationBarHidden ? "Yes" : "No");
    
    // last error seen - used to avoid seeing twice the same error in the error dialog box
    lastErrorCode = 99;
}

- (void)viewWillDisappear:(BOOL)animated
{
    // on iOS 7, viewWillDisappear may be called when the menu is shown
    // but we don't want to stop the AR view in that case
    if (self.showingMenu) {
        return;
    }
    
    [vapp stopAR:nil];
    
    // Be a good OpenGL ES citizen: now that Vuforia is paused and the render
    // thread is not executing, inform the root view controller that the
    // EAGLView should finish any OpenGL ES commands
    [self finishOpenGLESCommands];
    
    VuforiaSamplesAppDelegate *appDelegate = (VuforiaSamplesAppDelegate*)[[UIApplication sharedApplication] delegate];
    appDelegate.glResourceHandler = nil;
    
    [super viewWillDisappear:animated];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)finishOpenGLESCommands
{
    // Called in response to applicationWillResignActive.  Inform the EAGLView
    [eaglView finishOpenGLESCommands];
}

- (void)freeOpenGLESResources
{
    // Called in response to applicationDidEnterBackground.  Inform the EAGLView
    [eaglView freeOpenGLESResources];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

-(void)showUIAlertFromErrorCode:(int)code
{
    if (lastErrorCode == code)
    {
        // we don't want to show twice the same error
        return;
    }
    lastErrorCode = code;
    
    NSString *title = nil;
    NSString *message = nil;
    
    if (code == Vuforia::TargetFinder::UPDATE_ERROR_NO_NETWORK_CONNECTION)
    {
        title = @"Network Unavailable";
        message = @"Please check your internet connection and try again.";
    }
    else if (code == Vuforia::TargetFinder::UPDATE_ERROR_REQUEST_TIMEOUT)
    {
        title = @"Request Timeout";
        message = @"The network request has timed out, please check your internet connection and try again.";
    }
    else if (code == Vuforia::TargetFinder::UPDATE_ERROR_SERVICE_NOT_AVAILABLE)
    {
        title = @"Service Unavailable";
        message = @"The cloud recognition service is unavailable, please try again later.";
    }
    else if (code == Vuforia::TargetFinder::UPDATE_ERROR_UPDATE_SDK)
    {
        title = @"Unsupported Version";
        message = @"The application is using an unsupported version of Vuforia.";
    }
    else if (code == Vuforia::TargetFinder::UPDATE_ERROR_TIMESTAMP_OUT_OF_RANGE)
    {
        title = @"Clock Sync Error";
        message = @"Please update the date and time and try again.";
    }
    else if (code == Vuforia::TargetFinder::UPDATE_ERROR_AUTHORIZATION_FAILED)
    {
        title = @"Authorization Error";
        message = @"The cloud recognition service access keys are incorrect or have expired.";
    }
    else if (code == Vuforia::TargetFinder::UPDATE_ERROR_PROJECT_SUSPENDED)
    {
        title = @"Authorization Error";
        message = @"The cloud recognition service has been suspended.";
    }
    else if (code == Vuforia::TargetFinder::UPDATE_ERROR_BAD_FRAME_QUALITY)
    {
        title = @"Poor Camera Image";
        message = @"The camera does not have enough detail, please try again later";
    }
    else
    {
        title = @"Unknown error";
        message = [NSString stringWithFormat:@"An unknown error has occurred (Code %d)", code];
    }
    
    //  Call the UIAlert on the main thread to avoid undesired behaviors
    dispatch_async( dispatch_get_main_queue(), ^{
        if (title && message)
        {
            
            UIAlertController *uiAlertController =
            [UIAlertController alertControllerWithTitle:@"Error"
                                                message:message
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *defaultAction =
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:^(UIAlertAction *action) {
                                       [[NSNotificationCenter defaultCenter] postNotificationName:@"kDismissARViewController" object:nil];
                                   }];
            
            [uiAlertController addAction:defaultAction];
            [self presentViewController:uiAlertController animated:YES completion:nil];
        }
    });
}


#pragma mark - loading animation

- (void) showLoadingAnimation {
    CGRect indicatorBounds;
    CGRect mainBounds = [[UIScreen mainScreen] bounds];
    int smallerBoundsSize = MIN(mainBounds.size.width, mainBounds.size.height);
    int largerBoundsSize = MAX(mainBounds.size.width, mainBounds.size.height);
    UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
    if (orientation == UIInterfaceOrientationPortrait || orientation == UIInterfaceOrientationPortraitUpsideDown ) {
        indicatorBounds = CGRectMake(smallerBoundsSize / 2 - 12,
                                     largerBoundsSize / 2 - 12, 24, 24);
    }
    else {
        indicatorBounds = CGRectMake(largerBoundsSize / 2 - 12,
                                     smallerBoundsSize / 2 - 12, 24, 24);
    }
    
    UIActivityIndicatorView *loadingIndicator = [[UIActivityIndicatorView alloc]
                                                  initWithFrame:indicatorBounds];
    
    loadingIndicator.tag  = 1;
    loadingIndicator.activityIndicatorViewStyle = UIActivityIndicatorViewStyleWhiteLarge;
    [eaglView addSubview:loadingIndicator];
    [loadingIndicator startAnimating];
}

- (void) hideLoadingAnimation {
    UIActivityIndicatorView *loadingIndicator = (UIActivityIndicatorView *)[eaglView viewWithTag:1];
    [loadingIndicator removeFromSuperview];
}


#pragma mark - SampleApplicationControl

- (bool) doInitTrackers
{
    // To get the best performance for the DeviceTracker in this application
    // we ensure that the most optimal fusion provider is being used.
    // For CloudReco, the recommended fusion provider mode is
    // the FUSION_OPTIMIZE_IMAGE_TARGETS_AND_VUMARKS enum
    if (![vapp setFusionProviderType:Vuforia::FUSION_PROVIDER_TYPE::FUSION_OPTIMIZE_IMAGE_TARGETS_AND_VUMARKS])
    {
        return NO;
    }
    
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    
    // Initialize the object tracker
    Vuforia::Tracker* objectTracker = trackerManager.initTracker(Vuforia::ObjectTracker::getClassType());
    if (objectTracker == nullptr)
    {
        NSLog(@"Failed to initialize ObjectTracker.");
        return false;
    }
    
    // Initialize the device tracker
    Vuforia::Tracker* deviceTracker = trackerManager.initTracker(Vuforia::PositionalDeviceTracker::getClassType());
    if (deviceTracker == nullptr)
    {
        NSLog(@"Failed to initialize DeviceTracker.");
        return false;
    }
    
    NSLog(@"Initialized trackers");
    return true;
}

- (bool) doLoadTrackersData {
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
    if (objectTracker == NULL)
    {
        NSLog(@">doLoadTrackersData>Failed to load tracking data set because the ImageTracker has not been initialized.");
        return false;
        
    }
    
    
    NSDate *start = [NSDate date];
    // Start initialization:

    Vuforia::TargetFinder* targetFinder = objectTracker->getTargetFinder();
    if (targetFinder == NULL)
    {
        NSLog(@">doLoadTrackersData>Failed to get target finder.");
        return false;
    }
    
    targetFinder->startInit(kAccessKey, kSecretKey);

    targetFinder->waitUntilInitFinished();
    
    NSDate *methodFinish = [NSDate date];
    NSTimeInterval executionTime = [methodFinish timeIntervalSinceDate:start];
    
    NSLog(@"waitUntilInitFinished Execution Time: %lf", executionTime);

    int resultCode = targetFinder->getInitState();
    if ( resultCode != Vuforia::TargetFinder::INIT_SUCCESS)
    {
        NSLog(@">doLoadTrackersData>Failed to initialize target finder.");
        if (resultCode == Vuforia::TargetFinder::INIT_ERROR_NO_NETWORK_CONNECTION)
        {
            NSLog(@"CloudReco error:Vuforia::TargetFinder::INIT_ERROR_NO_NETWORK_CONNECTION");
        }
        else if (resultCode == Vuforia::TargetFinder::INIT_ERROR_SERVICE_NOT_AVAILABLE)
        {
            NSLog(@"CloudReco error:Vuforia::TargetFinder::INIT_ERROR_SERVICE_NOT_AVAILABLE");
        }
        else
        {
            NSLog(@"CloudReco error:%d", resultCode);
        }
        
        int initErrorCode;
        if(resultCode == Vuforia::TargetFinder::INIT_ERROR_NO_NETWORK_CONNECTION)
        {
            initErrorCode = Vuforia::TargetFinder::UPDATE_ERROR_NO_NETWORK_CONNECTION;
        }
        else
        {
            initErrorCode = Vuforia::TargetFinder::UPDATE_ERROR_SERVICE_NOT_AVAILABLE;
        }
        
        [self showUIAlertFromErrorCode: initErrorCode];
        
        return NO;
    }
    
    NSLog(@">doLoadTrackersData>target finder initialized");
    mTargetFinder = targetFinder;
    return true;
}

- (bool) doStartTrackers
{
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    
    // Start object tracker
    Vuforia::Tracker* objectTracker = trackerManager.getTracker(Vuforia::ObjectTracker::getClassType());
    
    if(objectTracker != nullptr && objectTracker->start())
    {
        NSLog(@"Successfully started object tracker");
    }
    else
    {
        NSLog(@"ERROR: Failed to start object tracker");
        return false;
    }
    
    // Start device tracker if enabled
    if (deviceTrackerEnabled)
    {
        [self setDeviceTrackerEnabled:YES];
    }
    
    return true;
}

- (void) onInitARDone:(NSError *)initError {
    // remove loading animation
    dispatch_async(dispatch_get_main_queue(), ^{
        UIActivityIndicatorView *loadingIndicator = (UIActivityIndicatorView *)[self->eaglView viewWithTag:1];
        [loadingIndicator removeFromSuperview];
    });
    
    if (initError == nil) {
        NSError * error = nil;
        [vapp startAR:Vuforia::CameraDevice::CAMERA_DIRECTION_BACK error:&error];
        
        [eaglView updateRenderingPrimitives];
        
        // by default, we try to set the continuous auto focus mode
        // and we update menu to reflect the state of continuous auto-focus
        continuousAutofocusEnabled = Vuforia::CameraDevice::getInstance().setFocusMode(Vuforia::CameraDevice::FOCUS_MODE_CONTINUOUSAUTO);
        
        [self scanlineStart];
        
    } else {
        NSLog(@"Error initializing AR:%@", [initError description]);
        
        dispatch_async( dispatch_get_main_queue(), ^{
            
            UIAlertController *uiAlertController =
            [UIAlertController alertControllerWithTitle:@"Error"
                                                message:[initError localizedDescription]
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *defaultAction =
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:^(UIAlertAction *action) {
                                       [[NSNotificationCenter defaultCenter] postNotificationName:@"kDismissARViewController" object:nil];
                                   }];
            
            [uiAlertController addAction:defaultAction];
            [self presentViewController:uiAlertController animated:YES completion:nil];
        });
    }
}

- (bool) doStopTrackers
{
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    
    // Stop the object tracker
    Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>
            (trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
    
    if (objectTracker != nullptr)
    {
        objectTracker->stop();
        
        // Stop cloud based recognition:
        Vuforia::TargetFinder* targetFinder = objectTracker->getTargetFinder();
        if (targetFinder != 0)
        {
            isVisualSearchOn = !targetFinder->stop();
        }
        
        
        NSLog(@"INFO: successfully stopped object tracker");
    }
    else
    {
        NSLog(@"ERROR: failed to get the object tracker from the tracker manager");
    }
    
    // Stop the device tracker
    if(deviceTrackerEnabled)
    {
        Vuforia::Tracker* deviceTracker = trackerManager.getTracker(Vuforia::PositionalDeviceTracker::getClassType());
        
        if (deviceTracker != nullptr)
        {
            deviceTracker->stop();
            NSLog(@"INFO: successfully stopped devicetracker");
        }
        else
        {
            NSLog(@"ERROR: failed to get the device tracker from the tracker manager");
        }
    }
    
    return true;
}

- (bool) doUnloadTrackersData {
    // Get the image tracker:
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
    
    if (objectTracker == NULL)
    {
        NSLog(@"Failed to unload tracking data set because the ObjectTracker has not been initialized.");
        return false;
    }
    
    // Deinitialize visual search:
    if (mTargetFinder != 0) {
        mTargetFinder->deinit();
    }
    return true;
}

- (bool) doDeinitTrackers
{
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    trackerManager.deinitTracker(Vuforia::ObjectTracker::getClassType());
    trackerManager.deinitTracker(Vuforia::PositionalDeviceTracker::getClassType());
    return true;
}

- (void)dismissARViewController
{
    [self.navigationController setNavigationBarHidden:NO animated:YES];
    [self.navigationController popToRootViewControllerAnimated:NO];
}

- (void)configureVideoBackgroundWithViewWidth:(float)viewWidth andHeight:(float)viewHeight
{
    [eaglView configureVideoBackgroundWithViewWidth:(float)viewWidth andHeight:(float)viewHeight];
}

// update from the Vuforia loop
- (void) onVuforiaUpdate: (Vuforia::State *) state {
    // Get the target finder:
    if (!mTargetFinder) {
        return;
    }

    Vuforia::TargetFinder* finder = mTargetFinder;

    // Check if there are new results available:
    const auto& queryResult = finder->updateQueryResults();
    if (queryResult.status < 0)
    {
        // Show a message if we encountered an error:
        NSLog(@"update search result failed:%d", queryResult.status);
        if (queryResult.status == Vuforia::TargetFinder::UPDATE_ERROR_NO_NETWORK_CONNECTION)
        {
            [self showUIAlertFromErrorCode:queryResult.status];
        }
    }
    else if (queryResult.status == Vuforia::TargetFinder::UPDATE_RESULTS_AVAILABLE)
    {
        // Iterate through the new results:
        for (const auto* result : queryResult.results)
        {
            // Check if this target is suitable for tracking:
            if (result->getTrackingRating() > 0)
            {
                // Create a new Trackable from the result:
                Vuforia::Trackable* newTrackable = finder->enableTracking(*result);
                if (newTrackable != 0)
                {
                    //  Avoid entering on ContentMode when a bad target is found
                    //  (Bad Targets are targets that are exists on the CloudReco database but not on our
                    //  own book database)
                    NSLog(@"Successfully created new trackable '%s' with rating '%d'.",
                          newTrackable->getName(), result->getTrackingRating());
                }
                else
                {
                    NSLog(@"Failed to create new trackable.");
                }
            }
        }
    }
    
    if(resetTargetFinderTrackables)
    {
        Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
        Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
        Vuforia::TargetFinder* targetFinder = objectTracker->getTargetFinder();
        
        if(targetFinder)
        {
            targetFinder->clearTrackables();
            [self toggleVisualSearch:NO];
        }
        
        resetTargetFinderTrackables = NO;
    }
    
}

- (void) toggleVisualSearch {
    [self toggleVisualSearch:isVisualSearchOn];
}

- (void) toggleVisualSearch:(BOOL)visualSearchOn
{
    Vuforia::TrackerManager& trackerManager = Vuforia::TrackerManager::getInstance();
    Vuforia::ObjectTracker* objectTracker = static_cast<Vuforia::ObjectTracker*>(trackerManager.getTracker(Vuforia::ObjectTracker::getClassType()));
    
    if (objectTracker == 0) {
        NSLog(@"Failed to toggle Visual Search, as Object Tracker is null.");
        return;
    }
    
    if (!mTargetFinder) {
        return;
    }
    
    if (visualSearchOn == NO)
    {
        NSLog(@"Starting target finder");
        [self scanlineStart];
        mTargetFinder->startRecognition();
        isVisualSearchOn = YES;
    }
    else
    {
        NSLog(@"Stopping target finder");
        [self scanlineStop];
        mTargetFinder->stop();
        isVisualSearchOn = NO;
    }
}

- (IBAction)resetTargetFinder:(id)sender
{
    resetTargetFinderTrackables = YES;
}

- (void)autofocus:(UITapGestureRecognizer *)sender
{
    [self performSelector:@selector(cameraPerformAutoFocus) withObject:nil afterDelay:.4];
}

- (void)cameraPerformAutoFocus
{
    Vuforia::CameraDevice::getInstance().setFocusMode(Vuforia::CameraDevice::FOCUS_MODE_TRIGGERAUTO);
    
    // After triggering an autofocus event,
    // we must restore the previous focus mode
    if (continuousAutofocusEnabled)
    {
        [self performSelector:@selector(restoreContinuousAutoFocus) withObject:nil afterDelay:2.0];
    }
}

- (void)restoreContinuousAutoFocus
{
    Vuforia::CameraDevice::getInstance().setFocusMode(Vuforia::CameraDevice::FOCUS_MODE_CONTINUOUSAUTO);
}

- (void)doubleTapGestureAction:(UITapGestureRecognizer*)theGesture
{
    if (!self.showingMenu) {
        [self performSegueWithIdentifier: @"PresentMenu" sender: self];
    }
}

- (void)swipeGestureAction:(UISwipeGestureRecognizer*)gesture
{
    if (!self.showingMenu) {
        [self performSegueWithIdentifier:@"PresentMenu" sender:self];
    }
}


- (BOOL) setDeviceTrackerEnabled:(BOOL) enable
{
    BOOL result = YES;
    
    Vuforia::PositionalDeviceTracker* deviceTracker = static_cast<Vuforia::PositionalDeviceTracker*>
              (Vuforia::TrackerManager::getInstance()
              .getTracker(Vuforia::PositionalDeviceTracker::getClassType()));
    
    if (deviceTracker == NULL)
    {
        NSLog(@"ERROR: Could not toggle device tracker state");
        return NO;
    }
    
    if (enable)
    {
        if (deviceTracker->start())
        {
            NSLog(@"Successfully started device tracker");
        }
        else
        {
            result = NO;
            NSLog(@"Failed to start device tracker");
        }
    }
    else
    {
        deviceTracker->stop();
        NSLog(@"Successfully stopped device tracker");
    }
    
    if (result)
    {
        [eaglView setOffTargetTrackingMode:enable];
    }
    
    return result;
}

#pragma mark - menu delegate protocol implementation

- (BOOL) menuProcess:(NSString *)itemName value:(BOOL)value
{
    if ([@"Device Tracker" isEqualToString:itemName]) {
        deviceTrackerEnabled = value;
        [self setDeviceTrackerEnabled:deviceTrackerEnabled];
        return YES;
    }
    return NO;
}

- (void) menuDidExit
{
    self.showingMenu = NO;
}


#pragma mark - Navigation

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue isKindOfClass:[PresentMenuSegue class]]) {
        UIViewController *dest = [segue destinationViewController];
        if ([dest isKindOfClass:[SampleAppMenuViewController class]]) {
            self.showingMenu = YES;
            
            SampleAppMenuViewController *menuVC = (SampleAppMenuViewController *)dest;
            menuVC.menuDelegate = self;
            menuVC.sampleAppFeatureName = @"Cloud Reco";
            menuVC.dismissItemName = @"Vuforia Samples";
            menuVC.backSegueId = @"BackToCloudReco";
            
            // initialize menu item values (ON / OFF)
            [menuVC setValue:deviceTrackerEnabled forMenuItem:@"Device Tracker"];
        }
    }
}

#pragma mark - scan line
const int VIEW_SCAN_LINE_TAG = 1111;

- (void) scanlineCreate {
    CGRect frame = [[UIScreen mainScreen] bounds];

    UIImageView *scanLineView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, 50)];
    scanLineView.tag = VIEW_SCAN_LINE_TAG;
    scanLineView.contentMode = UIViewContentModeScaleToFill;
    [scanLineView setImage:[UIImage imageNamed:@"scanline.png"]];
    [scanLineView setHidden:YES];
    [self.view addSubview:scanLineView];
}

- (void) scanlineStart {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView * scanLineView = [self.view viewWithTag:VIEW_SCAN_LINE_TAG];
        if (scanLineView) {
            [scanLineView setHidden:NO];
            CGRect frame = [[UIScreen mainScreen] bounds];
          
            CABasicAnimation *animation = [CABasicAnimation
                                           animationWithKeyPath:@"position"];
          
            animation.toValue = [NSValue valueWithCGPoint:CGPointMake(scanLineView.center.x, frame.size.height)];
            animation.autoreverses = YES;
            animation.duration = 4.0;
            animation.repeatCount = HUGE_VAL;
            animation.removedOnCompletion = NO;
            animation.fillMode = kCAFillModeForwards;
            [scanLineView.layer addAnimation:animation forKey:@"position"];
        }
    });
}

- (void) scanlineStop {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView * scanLineView = [self.view viewWithTag:VIEW_SCAN_LINE_TAG];
        if (scanLineView) {
            [scanLineView setHidden:YES];
            [scanLineView.layer removeAllAnimations];
        }
    });
}

@end
