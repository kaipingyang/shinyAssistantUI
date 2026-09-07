# Create an on\_session\_load callback for ellmer session store

Returns a function suitable for the `on_session_load` argument of
`assistantUIServer()`, restoring chat turns from a
`ellmer_session_store()`.

## Usage

``` r
make_ellmer_session_loader(store)
```

## Arguments

  - store:
    
    A session store created by `ellmer_session_store()`.

## Value

A function with signature `function(session_id, thread_id,
send_thread)`.
