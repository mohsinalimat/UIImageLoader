# UIImageDiskCache

UIImageDiskCache is a helper to cache images on disk with additions for UIImage, UIImageView and UIButton.

It supports server cache control policies to re-download images when expired. Server cache control logic is implemented manually instead of using an NSURLCache for performance reasons.

You can also completely ignore server cache control and manually clean-up images yourself.

It's very small at roughly 700+ lines of code in a single header / implementation file.

Everything is asynchronous and uses modern objective-c with libdispatch and NSURLSession.

## Use Case

This isn't intended to compete with other frameworks that are optimized to provide fast scrolling for thousands or tens-of-thousands of images.

For average apps that would like to cache images on disk and have some options to control caching, this will make a noticeable difference.

My particular use case was a better disk cache that isn't NSURLCache. It provides better options for handling how server cache control policies are used. And get rid of delays or flickering that happens because of NSURLCache being slow.

## No Flickering or Noticeable Delayed Loads

Images that are cached and available on disk load into UIImageView or UIButton almost immediatly. This is most noticeable on table view cells.

## Server Cache Policies

It works with servers that support ETag/If-None-Match and Cache-Control headers.

If the server responds with only ETag you can optionally cache the image for a default amount of time. Or don't cache it at all and send requests each time to check for modified content.

If a response is 304 it uses the cached image available on disk.

## Installation

Download, fork, clone or submodule this repo. Then add UIImageDiskCache.h/m to your Xcode project.

## UIImageDiskCache Object

There's a default configured cache which you're free to configure how you like.

````
UIImageDiskCache * cache = [UIImageDiskCache defaultDiskCache];
//set cache properties here.
````

Or you can setup your own and configure it:

````
UIImageDiskCache * cache = [[UIImageDiskCache alloc] init];
//set cache properties here.
````

By default the cache will use server cache control policies. You can disable server cache control:

````
myCache.useServerCachePolicy = FALSE;
````

For responses that return an ETag header but no Cache-Control header you can set a default amount of time to cache those images for:

````
myCache.etagOnlyCacheControl = 604800; //1 week;
myCache.etagOnlyCacheControl = 0;      //(default) always send request to see if there's new content.
````

### Manual Disk Cache Cleanup

If you ignore server cache control you should put some kind of cleanup to remove old files. There are a few helper methods available:

````
- (void) clearCachedFilesOlderThan1Day;
- (void) clearCachedFilesOlderThan1Week;
- (void) clearCachedFilesOlderThan:(NSTimeInterval) timeInterval;
````

These methods use the file modified date to decide which to delete. Images that are used frequently will not be removed. When an image is accessed using the cache the modified date is updated.

Put some cleanup in app delegate:

````
- (BOOL) application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    UIImageDiskCache * cache = [UIImageDiskCache defaultDiskCache];
    [cache clearCachedFilesOlderThan1Week];
}
````

### UIImage & UIImageView & UIButton

If you want to use the default cache, use one of these methods:

````
UIImage:
- (NSURLSessionDataTask *) downloadImageWithURL:(NSURL *) url completion:(UIImageDiskCacheCompletion) completion;
- (NSURLSessionDataTask *) downloadImageWithRequest:(NSURLRequest *) request completion:(UIImageDiskCacheCompletion) completion;

UIImageView:
- (NSURLSessionDataTask *) setImageWithURL:(NSURL *) url completion:(UIImageDiskCacheCompletion) completion;
- (NSURLSessionDataTask *) setImageWithRequest:(NSURLRequest *) request completion:(UIImageDiskCacheCompletion) completion;

UIButton:
- (NSURLSessionDataTask *) setImageForControlState:(UIControlState) controlState withURL:(NSURL *) url completion:(UIImageDiskCacheCompletion) completion;
- (NSURLSessionDataTask *) setImageForControlState:(UIControlState) controlState withRequest:(NSURLRequest *) request completion:(UIImageDiskCacheCompletion) completion;
- (NSURLSessionDataTask *) setBackgroundImageForControlState:(UIControlState) controlState withURL:(NSURL *) url completion:(UIImageDiskCacheCompletion) completion;
- (NSURLSessionDataTask *) setBackgroundImageForControlState:(UIControlState) controlState withRequest:(NSURLRequest *) request completion:(UIImageDiskCacheCompletion) completion;
````

If you use a custom configured cache use these methods:

````
UIImage:
- (NSURLSessionDataTask *) downloadImageWithURL:(NSURL *) url customCache:(UIImageDiskCache *) customCache completion:(UIImageDiskCacheCompletion) completion;
- (NSURLSessionDataTask *) downloadImageWithRequest:(NSURLRequest *) request customCache:(UIImageDiskCache *) customCache completion:(UIImageDiskCacheCompletion)completion;

UIImageView:
- (NSURLSessionDataTask *) setImageWithURL:(NSURL *) url customCache:(UIImageDiskCache *) customCache completion:(UIImageDiskCacheCompletion) completion;
- (NSURLSessionDataTask *) setImageWithRequest:(NSURLRequest *) request customCache:(UIImageDiskCache *) customCache - completion:(UIImageDiskCacheCompletion) completion;

UIButton:
- (NSURLSessionDataTask *) setImageForControlState:(UIControlState) controlState withURL:(NSURL *) url customCache:(UIImageDiskCache *) customCache completion:(UIImageDiskCacheCompletion) completion;
- (NSURLSessionDataTask *) setImageForControlState:(UIControlState) controlState withRequest:(NSURLRequest *) request customCache:(UIImageDiskCache *) customCache completion:(UIImageDiskCacheCompletion) completion;
- (NSURLSessionDataTask *) setBackgroundImageForControlState:(UIControlState) controlState withURL:(NSURL *) url customCache:(UIImageDiskCache *) customCache completion:(UIImageDiskCacheCompletion) completion;
- (NSURLSessionDataTask *) setBackgroundImageForControlState:(UIControlState) controlState withRequest:(NSURLRequest *) request customCache:(UIImageDiskCache *) customCache completion:(UIImageDiskCacheCompletion) completion;
````

### NSURLSession

You can customize the NSURLSession that's used to download images like this:

````
myCache.session = myNSURLSession;
````

If you do change the session, you are responsible for implementing it's delegate if required. And implementing SSL trust for self signed certificates if required.

### NSURLSessionDataTask

Each helper method on UIImage, UIImageView, and UIButton returns an NSURLSessionDataTask. You can either use it or ignore it. It's useful if you ever needed to cancel an image request.

### UIImageDiskCacheCompletion

The completion callback is defined like this:

````
typedef void(^UIImageDiskCacheCompletion)
  (NSError * error, UIImage * image, NSURL * url, UIImageLoadSource loadedFromSource);
````

You always get a reference to the image, the request url, and where the image was loaded from.

For UIImageView and UIButton, the image is already set for you, you can safely ignore the image parameter. It's provided for you in case you need to do something else with it.

### UIImageLoadSource

UIImageLoadSource has these options available:

````
UIImageLoadSourceNone,          //no source as there was an error
UIImageLoadSourceNetworkToDisk, //a network request was sent before returning the image from disk
UIImageLoadSourceDisk,          //image was cached on disk already and loaded from disk
````

### Placeholder Images

Some other frameworks have the idea of placeholder images. UIImageDiskCache doesn't have these because you can set the image yourself before loading an image with UIImageDiskCache.

````
myImageView.image = [UIImage imageNamed:@"myPlaceholder"];
[myImageView setImageWithURL:myURL
    completion:^(NSError *error, UIImage *image, NSURL * url, UIImageLoadSource loadSource) {

}];
````

## Other Useful Features

### SSL

If you need to support self signed certificates you can use (false by default):

````
myCache.trustAnySSLCertificate = TRUE;
````

### Auth Basic Password Protected Directories/Images

You can set default user/pass that gets sent in every request with:

````
[myCache setAuthUsername:@"username" password:@"password"];
````


## License

The MIT License (MIT)
Copyright (c) 2016 Aaron Smith

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.