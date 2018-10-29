import glfw
import ../logging
import ../wiishtypes
import ../events

## List of created windows
var windows*:seq[wiishtypes.Window]

## The singleton application instance.
var app* = App()
app.launched = newEventSource[bool]()
app.willExit = newEventSource[bool]()

proc newWindow*():wiishtypes.Window =
  log "newWindow()"
  result = wiishtypes.Window()
  result.willExit = newEventSource[bool]()
  windows.add(result)

  var c = DefaultOpenglWindowConfig
  c.title = "Some title"
  result.glfwWindow = glfw.newWindow(c)

proc close*(win: var wiishtypes.Window) =
  log "window.close()"
  windows.del(windows.find(win))
  win.willExit.emit(true)
  win.glfwWindow.destroy()


proc mainloop(app:App) =
  log "mainloop()"
  var therehavebeenwindows = false
  while not(therehavebeenwindows) or (therehavebeenwindows and windows.len > 0):
    if not therehavebeenwindows and windows.len > 0:
      therehavebeenwindows = true
    var old_windows = windows # make a copy so that they can be removed from the seq within the loop
    for window in old_windows:
      var w = window
      if w.glfwWindow.shouldClose:
        w.close()
      else:
        if w.glfwWindow.isKeyDown(keyEscape):
          log "Escape key is down"
          w.glfwWindow.shouldClose = true
        w.glfwWindow.swapBuffers()
    pollEvents()
  log "mainloop finished, quitting now"
  app.willExit.emit(true)
  app.quit()

proc start*(app:App) =
  log "app.start()"
  glfw.initialize()
  app.launched.emit(true)
  app.mainloop()

proc quit*(app:App) =
  log "app.quit()"
  app.willExit.emit(true)
  for w in windows:
    var w = w
    w.close()
  glfw.terminate()

# Handle pressing of control-C
proc onControlC() {.noconv.} =
  log "onControlC()"
  app.quit()
  quit(1)
setControlCHook(onControlC)