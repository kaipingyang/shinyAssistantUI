capture_browser_window_errors <- function(browser, stage = function() "browser",
                                         trace_resize = FALSE) {
  events <- list()
  browser$Runtime$enable()
  browser$Page$enable()
  browser$Runtime$addBinding(name = "auiVerificationWindowError")
  browser$Runtime$bindingCalled(callback_ = function(event) {
    if (identical(event$name, "auiVerificationWindowError")) {
      detail <- jsonlite::fromJSON(event$payload, simplifyVector = FALSE)
      detail$stage <- stage()
      events[[length(events) + 1L]] <<- detail
      cat("WINDOW_ERROR ", jsonlite::toJSON(detail, auto_unbox = TRUE, null = "null"), "\n", sep = "")
    }
  })
  # Native ResizeObserver errors need a window listener; CDP exceptions miss them.
  resize_trace <- ""
  if (isTRUE(trace_resize)) {
    resize_trace <- paste0(
      "(()=>{const Native=window.ResizeObserver,origins={},rows=[];let next=0,active=null;",
      "window.__auiResizeEvidence=()=>{const ids=new Set(rows.map(row=>row.observer));",
      "return {rows,origins:Object.fromEntries([...ids].map(id=>[id,origins[id]]))}};",
      "window.ResizeObserver=class extends Native{constructor(callback){",
      "const id=++next,origin={stack:String(new Error().stack||'').slice(0,1800),createdDuringObserver:active};",
      "super((entries,observer)=>{rows.push({observer:id,time:performance.now(),",
      "targets:entries.slice(0,12).map(entry=>({tag:entry.target.tagName,",
      "slot:entry.target.getAttribute('data-slot'),className:String(entry.target.className).slice(0,160),",
      "width:entry.contentRect.width,height:entry.contentRect.height}))});",
      "if(rows.length>16)rows.shift();const previous=active;active=id;",
      "try{callback(entries,observer);}finally{active=previous;}});origins[id]=origin;}};})();"
    )
  }
  browser$Page$addScriptToEvaluateOnNewDocument(source = paste0(
    resize_trace,
    "window.__auiWindowErrorProbeReady=true;",
    "window.addEventListener('error',event=>window.auiVerificationWindowError(JSON.stringify({",
    "category:event instanceof ErrorEvent?'script':'resource',message:event.message||'',",
    "hasErrorObject:!!event.error,stack:String(event.error?.stack||'').slice(0,2000),",
    "line:event.lineno||0,column:event.colno||0,",
    "resizeEvidence:window.__auiResizeEvidence?.()||null})));"
  ))
  function() events
}
