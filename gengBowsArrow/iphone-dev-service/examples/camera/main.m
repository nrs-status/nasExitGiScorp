// examples/camera/main.m — minimal iOS camera app template.
//
// Captures a photo with AVFoundation and writes the JPEG into the app's
// Documents directory. It exists as a compiling starting point for agents
// using the iphone-dev-service package; see ../BUILDING-APPS.md.
//
// Build + install:
//   APP_NAME=HelloCamera BUNDLE_ID=com.example.hellocamera \
//   FRAMEWORKS="Foundation UIKit AVFoundation" \
//   iphone-dev-service build-install examples/camera

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface ViewController : UIViewController <AVCapturePhotoCaptureDelegate>
@property (nonatomic) AVCaptureSession *session;
@property (nonatomic) AVCapturePhotoOutput *output;
@property (nonatomic) AVCaptureVideoPreviewLayer *preview;
@property (nonatomic) UILabel *status;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    self.status = [[UILabel alloc] initWithFrame:CGRectMake(16, 60,
                        self.view.bounds.size.width - 32, 100)];
    self.status.numberOfLines = 4;
    self.status.textColor = UIColor.whiteColor;
    self.status.font = [UIFont systemFontOfSize:15];
    self.status.text = @"Starting camera...";
    [self.view addSubview:self.status];

    UIButton *shoot = [UIButton buttonWithType:UIButtonTypeSystem];
    [shoot setTitle:@"Capture" forState:UIControlStateNormal];
    [shoot setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    shoot.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    shoot.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.85];
    shoot.layer.cornerRadius = 12;
    shoot.frame = CGRectMake(0, 0, 200, 56);
    shoot.center = CGPointMake(self.view.bounds.size.width / 2,
                               self.view.bounds.size.height - 70);
    shoot.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [shoot addTarget:self action:@selector(capture:)
            forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:shoot];

    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                             completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            granted ? [self startCamera]
                    : (self.status.text = @"Camera access denied.");
        });
    }];
}

- (void)startCamera {
    self.session = [AVCaptureSession new];
    self.session.sessionPreset = AVCaptureSessionPresetPhoto;

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) { self.status.text = [NSString stringWithFormat:@"no camera: %@", error]; return; }
    [self.session addInput:input];

    self.output = [AVCapturePhotoOutput new];
    [self.session addOutput:self.output];

    self.preview = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    self.preview.frame = self.view.bounds;
    self.preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.view.layer insertSublayer:self.preview atIndex:0];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self.session startRunning];
    });
    self.status.text = @"Ready.";
}

- (void)capture:(id)sender {
    if (!self.session.isRunning) return;
    self.status.text = @"Capturing...";
    AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
    [self.output capturePhotoWithSettings:settings delegate:self];
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
    didFinishProcessingPhoto:(AVCapturePhoto *)photo
                        error:(NSError *)error {
    if (error || !photo) { self.status.text = [NSString stringWithFormat:@"error: %@", error]; return; }
    NSData *jpeg = [photo fileDataRepresentation];
    NSString *name = [NSString stringWithFormat:@"capture-%u.jpg", arc4random_uniform(0xFFFFFF)];
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES).firstObject
                      stringByAppendingPathComponent:name];
    [jpeg writeToFile:path atomically:YES];
    self.status.text = [NSString stringWithFormat:@"wrote %lu KB to\n%@",
                        (unsigned long)(jpeg.length / 1024), path];
    NSLog(@"[HelloCamera] wrote %@", path);
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app
    didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [ViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}