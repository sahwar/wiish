import os
import osproc
import re
import ospaths
import logging
import strformat
import strutils
import tables
import posix
import parsetoml

import ./config
import ./buildutil

proc getEnvOrFail(name: string, errmessage: string = ""): string =
  if existsEnv(name):
    getEnv(name)
  else:
    raise newException(CatchableError, &"Environment variable {name} must be set.  {errmessage}")

proc replaceInFile(filename: string, replacements: Table[string, string]) =
  ## Replace lines in a file with the given replacements
  var guts = filename.readFile()
  for pattern, replacement in replacements:
    guts = guts.replace(re(pattern), replacement)
  filename.writeFile(guts)

template activityName(config:Config):string =
  config.java_package_name.split({'.'})[^1] & "Activity"

template fullActivityName(config:Config):string =
  ## Return the java.style.activity.name of an app
  config.java_package_name & "." & config.activityName()

proc doAndroidBuild*(directory:string, configPath:string): string =
  ## Package an Android app
  ## Returns the path to the app

  # From SDL2 source, following:
  # - ./docs/README-android.md
  # - ./build-scripts/androidbuild.sh
  let
    config = getAndroidConfig(configPath)
    projectDir = directory/config.dst/"android"/"project"/config.java_package_name
    appSrc = directory/config.src
    sdlSrc = DATADIR/"SDL"
    appProject = projectDir/"app/jni/app"
    # androidNDKPath = getEnvOrFail("ANDROID_NDK", "Set to your local Android NDK path.  Download from https://developer.android.com/ndk/downloads/")
    # androidSDKPath = getEnvOrFail("ANDROID_SDK", "Set to your local Android SDK path.  Download from https://developer.android.com/studio/#downloads")
  var
    ndkArgs: seq[string]
  
  if not projectDir.existsDir():
    debug &"Copying SDL android project to {projectDir}"
    createDir(projectDir)
    copyDirWithPermissions(sdlSrc/"android-project", projectDir)

    # Copy in SDL source
    copyDirWithPermissions(sdlSrc/"src", projectDir/"app/jni/SDL/src")
    copyDirWithPermissions(sdlSrc/"include", projectDir/"app/jni/SDL/include")
    
    # Android.mk
    let android_mk = projectDir/"app/jni/SDL/Android.mk"
    copyFile(sdlSrc/"Android.mk", android_mk)
    replaceInFile(projectDir/"app/build.gradle", {
      "org.libsdl.app": config.java_package_name,
    }.toTable)
    replaceInFile(projectDir/"app/src/main/AndroidManifest.xml", {
      "org.libsdl.app": config.java_package_name,
    }.toTable)

  debug "Compiling Nim portion ..."
  proc buildFor(android_abi:string, cpu:string) =
    var nimFlags:seq[string]
    nimFlags.add(["nim", "c"])
    nimFlags.add([
      "--os:android",
      "-d:android",
      &"--cpu:{cpu}",
      # "--dynlibOverride:SDL2",
      "--noMain",
      "--header",
      "--compileOnly",
      # "--app:lib",
      # "--passL:-lGLESv1_CM",
      # "--passL:-lGLESv2",
      "--nimcache:" & projectDir/"app/jni/src"/android_abi,
      # "--out:" & appProject/arch_abi/"libmain.so",
      appSrc,
    ])
    debug nimFlags.join(" ")
    run(nimFlags)

  # Android ABIs: https://developer.android.com/ndk/guides/android_mk#taa
  # nim --cpus: https://github.com/nim-lang/Nim/blob/devel/lib/system/platforms.nim#L14
  buildFor("armeabi-v7a", "arm")
  buildFor("arm64-v8a", "arm64")
  buildFor("x86", "i386")
  buildFor("x86_64", "amd64")

# # https://developer.android.com/ndk/guides/prebuilts
#   debug "Create application code Android.mk ..."
#   writeFile(appProject/"Android.mk", """
# LOCAL_PATH := $(call my-dir)

# include $(CLEAR_VARS)
# LOCAL_MODULE := main
# LOCAL_SRC_FILES := $(TARGET_ARCH_ABI)/libmain.so
# include $(PREBUILT_SHARED_LIBRARY)
# """)

  debug "Create Activity ..."
  let
    activity_name = config.activityName()
    activity_java_path = projectDir/"app/src/main/java"/config.java_package_name.replace(".", "/")/activity_name&".java"
  activity_java_path.parentDir.createDir()
  debug activity_java_path
  writeFile(activity_java_path, &"""
package {config.java_package_name};

import org.libsdl.app.SDLActivity;

public class {activity_name} extends SDLActivity
{{
}}
""")

  replaceInFile(projectDir/"app/src/main/AndroidManifest.xml", {
    "SDLActivity": activity_name,
  }.toTable)

  replaceInFile(projectDir/"app/build.gradle", {
    "abiFilters.*?\n": "abiFilters 'arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64'\n",
  }.toTable)
  
  var cfiles : seq[string]
  debug "Listing c files ..."
  for item in walkDir(projectDir/"app/jni/src/x86"):
    if item.kind == pcFile and item.path.endsWith(".c"):
      cfiles.add(&"$(TARGET_ARCH_ABI)/{item.path.basename}")
  
  let nimlib = getNimLibPath()
  debug &"nimlib: {nimlib}"
  writeFile(projectDir/"app/jni/src/Android.mk",
&"""
LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := main
LOCAL_C_INCLUDES := $(LOCAL_PATH)/../SDL/include {nimlib}
LOCAL_SRC_FILES := {cfiles.join(" ")}
LOCAL_SHARED_LIBRARIES := SDL2
LOCAL_LDLIBS := -lGLESv1_CM -lGLESv2 -llog

include $(BUILD_SHARED_LIBRARY)
""")

  debug &"Building with gradle in {projectDir} ..."
  withDir(projectDir):
    run("./gradlew", "bundleDebug")
  
  result = projectDir/"app/build/outputs/apk/debug/app-debug.apk"

template runningDevices() : seq[string] = 
  ## List all currently running Android devices
  runoutput("adb", "devices").strip.splitLines[1..^1]

proc doAndroidRun*(directory: string) =
  ## Run the application in the Android emulator
  let
    configPath = directory/"wiish.toml"
    config = getAndroidConfig(configPath)

  debug "Building app ..."
  let apkPath = doAndroidBuild(directory, configPath)

  debug "Opening emulator ..."
  let device_list = runningDevices()
  echo "devices: ", device_list
  if device_list.len == 0:
    let possible_avds = runoutput("emulator", "-list-avds").strip.splitLines
    if possible_avds.len == 0:
      raise newException(CatchableError, "No emulators installed. XXX provide instructions to get them installed.")
    let avd = possible_avds[0]
    debug &"Launching {avd} ..."
    var p = startProcess(command="emulator", args = @["-avd", possible_avds[0]], options = {poUsePath})
    # XXX it would maybe be nice to leave this running...
    debug "Waiting for device to boot ..."
    run("adb", "wait-for-local-device")
  
  debug &"Installing apk {apkPath} ..."
  run("adb", "install", "-r", "-t", apkPath)

  debug &"Watching logs ..."
  var logp = startProcess(command="adb", args = @["logcat", "-T", "0"], options = {poUsePath, poParentStreams})

  let
    fullActivityName = config.fullActivityName()
    fullAppName = fullActivityName.split({'.'})[0..^2].join(".") & "/" & fullActivityName
  debug &"Starting app ({fullActivityName}) on device ..."
  debug fullAppName
  run("adb", "shell", "am", "start", "-a", "android.intent.action.MAIN", "-n", fullAppName)

  discard logp.waitForExit()
