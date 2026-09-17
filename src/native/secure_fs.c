#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/syscall.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stddef.h>
#include <pthread.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif
#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif
#ifndef SOCK_NONBLOCK
#define SOCK_NONBLOCK 0
#endif
#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC 0
#endif
#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif

#define SAUI_RING_FRAMES 256
#define SAUI_RING_BYTES (8 * 1024 * 1024)
typedef struct {
  int fd; char *path; int receiver_started; volatile int stop;
  pthread_t thread; pthread_mutex_t mutex;
  unsigned char *frames[SAUI_RING_FRAMES]; size_t lengths[SAUI_RING_FRAMES];
  size_t head, tail, count, bytes;
} saui_handle;

static SEXP scalar_bool(int value) { return ScalarLogical(value ? 1 : 0); }
static SEXP scalar_chr(const char *value) { return mkString(value); }
static SEXP named_list(int n, const char **names) {
  SEXP out = PROTECT(allocVector(VECSXP, n));
  SEXP nms = PROTECT(allocVector(STRSXP, n));
  for (int i = 0; i < n; ++i) SET_STRING_ELT(nms, i, mkChar(names[i]));
  setAttrib(out, R_NamesSymbol, nms);
  UNPROTECT(2);
  return out;
}
static const char *one_string(SEXP value) {
  if (TYPEOF(value) != STRSXP || XLENGTH(value) != 1 || STRING_ELT(value, 0) == NA_STRING)
    error("expected one string");
  return CHAR(STRING_ELT(value, 0));
}
static int safe_basename(const char *name) {
  if (!name || !*name || !strcmp(name, ".") || !strcmp(name, "..") || strchr(name, '/')) return 0;
  return strlen(name) <= NAME_MAX;
}
static void handle_finalizer(SEXP ptr) {
  saui_handle *h = (saui_handle *) R_ExternalPtrAddr(ptr);
  if (!h) return;
  if(h->receiver_started){h->stop=1;pthread_join(h->thread,NULL);pthread_mutex_lock(&h->mutex);for(size_t i=0;i<h->count;i++){size_t pos=(h->head+i)%SAUI_RING_FRAMES;free(h->frames[pos]);}pthread_mutex_unlock(&h->mutex);pthread_mutex_destroy(&h->mutex);}
  if (h->fd >= 0) close(h->fd);
  if (h->path) { unlink(h->path); free(h->path); }
  free(h); R_ClearExternalPtr(ptr);
}
static saui_handle *get_handle(SEXP ptr) {
  if (TYPEOF(ptr) != EXTPTRSXP) error("invalid native handle");
  saui_handle *h = (saui_handle *) R_ExternalPtrAddr(ptr);
  if (!h || h->fd < 0) error("closed native handle");
  return h;
}
static SEXP make_handle(int fd, const char *path) {
  saui_handle *h = calloc(1, sizeof(*h));
  if (!h) { close(fd); error("native allocation failed"); }
  h->fd = fd; h->path = path ? strdup(path) : NULL;
  SEXP ptr = PROTECT(R_MakeExternalPtr(h, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(ptr, handle_finalizer, TRUE);
  UNPROTECT(1); return ptr;
}
static void *dgram_receiver(void *data){
  saui_handle *h=(saui_handle*)data;unsigned char buffer[32769];
  while(!h->stop){ssize_t n=recv(h->fd,buffer,sizeof(buffer),MSG_DONTWAIT);if(n<0){if(errno==EAGAIN||errno==EWOULDBLOCK){usleep(1000);continue;}break;}if(n==0||n>32768)continue;
    unsigned char *copy=malloc((size_t)n);if(!copy)continue;memcpy(copy,buffer,(size_t)n);
    pthread_mutex_lock(&h->mutex);if(h->count>=SAUI_RING_FRAMES||h->bytes+(size_t)n>SAUI_RING_BYTES){pthread_mutex_unlock(&h->mutex);free(copy);continue;}
    h->frames[h->tail]=copy;h->lengths[h->tail]=(size_t)n;h->tail=(h->tail+1)%SAUI_RING_FRAMES;h->count++;h->bytes+=(size_t)n;pthread_mutex_unlock(&h->mutex);
  }return NULL;
}
static int start_receiver(saui_handle *h){if(pthread_mutex_init(&h->mutex,NULL))return -1;h->receiver_started=1;if(pthread_create(&h->thread,NULL,dgram_receiver,h)){h->receiver_started=0;pthread_mutex_destroy(&h->mutex);return -1;}return 0;}
static int fsync_parent_path(const char *path) {
  char copy[PATH_MAX];
  if (strlen(path) >= sizeof(copy)) return -1;
  strcpy(copy, path); char *slash = strrchr(copy, '/');
  if (!slash) strcpy(copy, "."); else if (slash == copy) slash[1] = '\0'; else *slash = '\0';
  int fd = open(copy, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fd < 0) return -1; int ok = fsync(fd); int saved = errno; close(fd); errno = saved; return ok;
}
static int rename_noreplace_at(int oldfd, const char *oldname, int newfd, const char *newname) {
#ifdef SYS_renameat2
  return (int) syscall(SYS_renameat2, oldfd, oldname, newfd, newname, RENAME_NOREPLACE);
#else
  errno = ENOTSUP; return -1;
#endif
}
static int publish_noreplace_at(int oldfd, const char *oldname, int newfd, const char *newname) {
  if(rename_noreplace_at(oldfd,oldname,newfd,newname)==0)return 0;
  int first=errno;
  if(first!=ENOTSUP&&first!=EOPNOTSUPP&&first!=ENOSYS&&first!=EINVAL){errno=first;return -1;}
  if(linkat(oldfd,oldname,newfd,newname,0))return -1;
  if(unlinkat(oldfd,oldname,0)){int saved=errno;unlinkat(newfd,newname,0);errno=saved;return -1;}
  return 0;
}
static int read_start_token(pid_t pid, char *out, size_t cap) {
  char path[64], buf[4096]; snprintf(path, sizeof(path), "/proc/%ld/stat", (long) pid);
  int fd = open(path, O_RDONLY | O_CLOEXEC); if (fd < 0) return -1;
  ssize_t n = read(fd, buf, sizeof(buf)-1); int saved = errno; close(fd); errno = saved;
  if (n <= 0) return -1; buf[n] = '\0'; char *end = strrchr(buf, ')'); if (!end) return -1;
  char *p = end + 1; while (*p == ' ') ++p;
  int field = 3; char *save = NULL; char *tok = strtok_r(p, " ", &save);
  while (tok && field < 22) { tok = strtok_r(NULL, " ", &save); ++field; }
  if (!tok || field != 22 || strlen(tok) + 1 > cap) return -1;
  strcpy(out, tok); return 0;
}

SEXP saui_native_capabilities(void) {
  const char *names[] = {"version","platform","secureFs","unixDatagram","parentDeath","noReplace"};
  SEXP out = PROTECT(named_list(6, names));
  SET_VECTOR_ELT(out,0,ScalarInteger(1));
#ifdef __linux__
  SET_VECTOR_ELT(out,1,scalar_chr("linux")); SET_VECTOR_ELT(out,2,scalar_bool(1));
  SET_VECTOR_ELT(out,3,scalar_bool(1)); SET_VECTOR_ELT(out,4,scalar_bool(1)); SET_VECTOR_ELT(out,5,scalar_bool(1));
#else
  SET_VECTOR_ELT(out,1,scalar_chr("unsupported")); SET_VECTOR_ELT(out,2,scalar_bool(0));
  SET_VECTOR_ELT(out,3,scalar_bool(0)); SET_VECTOR_ELT(out,4,scalar_bool(0)); SET_VECTOR_ELT(out,5,scalar_bool(0));
#endif
  UNPROTECT(1); return out;
}

SEXP saui_fs_open_root(SEXP path_s) {
  const char *path = one_string(path_s); char real[PATH_MAX]; struct stat st;
  if (!realpath(path, real) || lstat(real, &st) || !S_ISDIR(st.st_mode) || st.st_uid != geteuid()) return R_NilValue;
  int fd = open(real, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return R_NilValue;
  if (fchmod(fd, 0700) || fsync(fd)) { close(fd); return R_NilValue; }
  return make_handle(fd, NULL);
}
static SEXP stat_result(const struct stat *st) {
  const char *names[] = {"dev","ino","mode","nlink","size","mtime","ctime","uid","regular"};
  SEXP out = PROTECT(named_list(9,names));
  SET_VECTOR_ELT(out,0,ScalarReal((double)st->st_dev)); SET_VECTOR_ELT(out,1,ScalarReal((double)st->st_ino));
  SET_VECTOR_ELT(out,2,ScalarInteger((int)(st->st_mode & 07777))); SET_VECTOR_ELT(out,3,ScalarReal((double)st->st_nlink));
  SET_VECTOR_ELT(out,4,ScalarReal((double)st->st_size)); SET_VECTOR_ELT(out,5,ScalarReal((double)st->st_mtime));
  SET_VECTOR_ELT(out,6,ScalarReal((double)st->st_ctime)); SET_VECTOR_ELT(out,7,ScalarReal((double)st->st_uid));
  SET_VECTOR_ELT(out,8,scalar_bool(S_ISREG(st->st_mode)));
  UNPROTECT(1); return out;
}
SEXP saui_fs_stat_at(SEXP root_s, SEXP name_s) {
  saui_handle *root = get_handle(root_s); const char *name = one_string(name_s); if (!safe_basename(name)) return R_NilValue;
  struct stat before, after; if (fstatat(root->fd,name,&before,AT_SYMLINK_NOFOLLOW) || !S_ISREG(before.st_mode)) return R_NilValue;
  int fd = openat(root->fd,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC); if (fd < 0) return R_NilValue;
  int ok = fstat(fd,&after); close(fd); if (ok || before.st_dev!=after.st_dev || before.st_ino!=after.st_ino) return R_NilValue;
  return stat_result(&after);
}
SEXP saui_fs_atomic_write_at(SEXP root_s, SEXP tmp_s, SEXP final_s, SEXP raw_s) {
  saui_handle *root=get_handle(root_s); const char *tmp=one_string(tmp_s), *final=one_string(final_s);
  if (!safe_basename(tmp)||!safe_basename(final)||TYPEOF(raw_s)!=RAWSXP) return scalar_chr("invalid");
  int fd=openat(root->fd,tmp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600); if(fd<0) return scalar_chr(errno==EEXIST?"existing":"io_error");
  const unsigned char *p=RAW(raw_s); R_xlen_t left=XLENGTH(raw_s); int ok=1;
  while(left>0){ssize_t n=write(fd,p,(size_t)(left>SSIZE_MAX?SSIZE_MAX:left)); if(n<=0){ok=0;break;} p+=n;left-=n;}
  if(ok && (fchmod(fd,0600)||fsync(fd))) ok=0; close(fd);
  if(!ok){unlinkat(root->fd,tmp,0);return scalar_chr("io_error");}
  if(publish_noreplace_at(root->fd,tmp,root->fd,final)){int e=errno;unlinkat(root->fd,tmp,0);return scalar_chr(e==EEXIST?"existing":(e==ENOTSUP?"unsupported":"io_error"));}
  if(fsync(root->fd)) return scalar_chr("io_error"); return scalar_chr("ok");
}
SEXP saui_fs_remove_at(SEXP root_s, SEXP name_s, SEXP quarantine_s, SEXP dev_s, SEXP ino_s) {
  saui_handle *root=get_handle(root_s); const char *name=one_string(name_s), *q=one_string(quarantine_s);
  if(!safe_basename(name)||!safe_basename(q)) return scalar_chr("invalid");
  struct stat st; int fd=openat(root->fd,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC); if(fd<0)return scalar_chr(errno==ENOENT?"missing":"unsafe");
  int ok=!fstat(fd,&st)&&S_ISREG(st.st_mode)&&st.st_nlink==1&&
    (double)st.st_dev==asReal(dev_s)&&(double)st.st_ino==asReal(ino_s); close(fd);
  if(!ok)return scalar_chr("changed");
  if(publish_noreplace_at(root->fd,name,root->fd,q)){return scalar_chr(errno==EEXIST?"existing":"io_error");}
  if(fsync(root->fd)||unlinkat(root->fd,q,0)||fsync(root->fd)) return scalar_chr("io_error");
  return scalar_chr("ok");
}
SEXP saui_fs_fsync_root(SEXP root_s){saui_handle *root=get_handle(root_s);return scalar_bool(fsync(root->fd)==0);}

SEXP saui_dgram_open(SEXP path_s) {
#ifdef __linux__
  const char *path=one_string(path_s); size_t plen=strlen(path); int abstract=path[0]=='@';
  if(plen<2||plen>=sizeof(((struct sockaddr_un*)0)->sun_path))return R_NilValue;
  int fd=socket(AF_UNIX,SOCK_DGRAM|SOCK_NONBLOCK|SOCK_CLOEXEC,0); if(fd<0)return R_NilValue;
  int size=4*1024*1024; setsockopt(fd,SOL_SOCKET,SO_RCVBUF,&size,sizeof(size));
  struct sockaddr_un addr; memset(&addr,0,sizeof(addr));addr.sun_family=AF_UNIX;socklen_t alen;
  if(abstract){addr.sun_path[0]='\0';memcpy(addr.sun_path+1,path+1,plen-1);alen=(socklen_t)(offsetof(struct sockaddr_un,sun_path)+plen);}
  else{strcpy(addr.sun_path,path);alen=(socklen_t)sizeof(addr);unlink(path);}
  if(bind(fd,(struct sockaddr*)&addr,alen)||(!abstract&&chmod(path,0600))){close(fd);if(!abstract)unlink(path);return R_NilValue;}
  SEXP ptr=PROTECT(make_handle(fd,abstract?NULL:path));saui_handle *h=get_handle(ptr);if(start_receiver(h)){handle_finalizer(ptr);UNPROTECT(1);return R_NilValue;}UNPROTECT(1);return ptr;
#else
  return R_NilValue;
#endif
}
SEXP saui_dgram_client(SEXP path_s) {
#ifdef __linux__
  const char *path=one_string(path_s);size_t plen=strlen(path);int abstract=path[0]=='@';if(plen<2||plen>=sizeof(((struct sockaddr_un*)0)->sun_path))return R_NilValue;
  int fd=socket(AF_UNIX,SOCK_DGRAM|SOCK_NONBLOCK|SOCK_CLOEXEC,0);if(fd<0)return R_NilValue;int size=4*1024*1024;setsockopt(fd,SOL_SOCKET,SO_SNDBUF,&size,sizeof(size));
  struct sockaddr_un addr;memset(&addr,0,sizeof(addr));addr.sun_family=AF_UNIX;socklen_t alen;if(abstract){addr.sun_path[0]='\0';memcpy(addr.sun_path+1,path+1,plen-1);alen=(socklen_t)(offsetof(struct sockaddr_un,sun_path)+plen);}else{strcpy(addr.sun_path,path);alen=(socklen_t)sizeof(addr);}
  if(connect(fd,(struct sockaddr*)&addr,alen)){close(fd);return R_NilValue;}return make_handle(fd,NULL);
#else
  return R_NilValue;
#endif
}
SEXP saui_dgram_send_handle(SEXP handle_s, SEXP raw_s) {
  const char *names[]={"ok","category","bytes"};SEXP out=PROTECT(named_list(3,names));SET_VECTOR_ELT(out,0,scalar_bool(0));SET_VECTOR_ELT(out,1,scalar_chr("invalid"));SET_VECTOR_ELT(out,2,ScalarInteger(0));
  if(TYPEOF(raw_s)!=RAWSXP||XLENGTH(raw_s)>32768){SET_VECTOR_ELT(out,1,scalar_chr("oversize"));UNPROTECT(1);return out;}saui_handle *h=get_handle(handle_s);ssize_t n=send(h->fd,RAW(raw_s),(size_t)XLENGTH(raw_s),MSG_DONTWAIT);int e=errno;if(n==(ssize_t)XLENGTH(raw_s)){SET_VECTOR_ELT(out,0,scalar_bool(1));SET_VECTOR_ELT(out,1,scalar_chr("ok"));SET_VECTOR_ELT(out,2,ScalarInteger((int)n));}else SET_VECTOR_ELT(out,1,scalar_chr((e==EAGAIN||e==EWOULDBLOCK)?"would_block":((e==EPIPE||e==ECONNREFUSED)?"closed":"io_error")));UNPROTECT(1);return out;
}

SEXP saui_dgram_send(SEXP path_s, SEXP raw_s) {
  const char *names[]={"ok","category","bytes"}; SEXP out=PROTECT(named_list(3,names));
  SET_VECTOR_ELT(out,0,scalar_bool(0));SET_VECTOR_ELT(out,1,scalar_chr("unsupported"));SET_VECTOR_ELT(out,2,ScalarInteger(0));
#ifdef __linux__
  const char *path=one_string(path_s);size_t plen=strlen(path);int abstract=path[0]=='@';
  if(TYPEOF(raw_s)!=RAWSXP||XLENGTH(raw_s)>32768||plen<2||plen>=sizeof(((struct sockaddr_un*)0)->sun_path)){SET_VECTOR_ELT(out,1,scalar_chr("oversize"));UNPROTECT(1);return out;}
  int fd=socket(AF_UNIX,SOCK_DGRAM|SOCK_NONBLOCK|SOCK_CLOEXEC,0); if(fd<0){SET_VECTOR_ELT(out,1,scalar_chr("io_error"));UNPROTECT(1);return out;}
  int size=4*1024*1024;setsockopt(fd,SOL_SOCKET,SO_SNDBUF,&size,sizeof(size));
  struct sockaddr_un addr;memset(&addr,0,sizeof(addr));addr.sun_family=AF_UNIX;socklen_t alen;
  if(abstract){addr.sun_path[0]='\0';memcpy(addr.sun_path+1,path+1,plen-1);alen=(socklen_t)(offsetof(struct sockaddr_un,sun_path)+plen);}
  else{strcpy(addr.sun_path,path);alen=(socklen_t)sizeof(addr);}
  ssize_t n=sendto(fd,RAW(raw_s),(size_t)XLENGTH(raw_s),MSG_DONTWAIT,(struct sockaddr*)&addr,alen);int e=errno;close(fd);
  if(n==(ssize_t)XLENGTH(raw_s)){SET_VECTOR_ELT(out,0,scalar_bool(1));SET_VECTOR_ELT(out,1,scalar_chr("ok"));SET_VECTOR_ELT(out,2,ScalarInteger((int)n));}
  else SET_VECTOR_ELT(out,1,scalar_chr((e==EAGAIN||e==EWOULDBLOCK)?"would_block":(e==ENOENT?"closed":"io_error")));
#endif
  UNPROTECT(1);return out;
}
SEXP saui_dgram_recv(SEXP handle_s, SEXP max_s) {
  saui_handle *h=get_handle(handle_s);int max=asInteger(max_s);if(max<1||max>32768)error("invalid frame limit");
  pthread_mutex_lock(&h->mutex);if(!h->count){pthread_mutex_unlock(&h->mutex);return R_NilValue;}size_t n=h->lengths[h->head];unsigned char *data=h->frames[h->head];h->frames[h->head]=NULL;h->head=(h->head+1)%SAUI_RING_FRAMES;h->count--;h->bytes-=n;pthread_mutex_unlock(&h->mutex);
  if(n>(size_t)max){free(data);return allocVector(RAWSXP,0);}SEXP out=PROTECT(allocVector(RAWSXP,n));memcpy(RAW(out),data,n);free(data);UNPROTECT(1);return out;
}

static void parent_death_handler(int sig) { (void)sig; kill(-getpgrp(),SIGTERM); _exit(190); }
SEXP saui_parent_guard_bootstrap(SEXP ppid_s, SEXP token_s) {
#ifdef __linux__
  pid_t expected=(pid_t)asInteger(ppid_s);const char *token=one_string(token_s);char actual[128];
  if(expected<1||getppid()!=expected||read_start_token(expected,actual,sizeof(actual))||strcmp(actual,token))return scalar_bool(0);
  if(setpgid(0,0)&&errno!=EACCES&&!(errno==EPERM&&getpgrp()==getpid()))return scalar_bool(0);
  struct sigaction sa;memset(&sa,0,sizeof(sa));sa.sa_handler=parent_death_handler;sigemptyset(&sa.sa_mask);
  if(sigaction(SIGUSR1,&sa,NULL)||prctl(PR_SET_PDEATHSIG,SIGUSR1))return scalar_bool(0);
  if(getppid()!=expected||read_start_token(expected,actual,sizeof(actual))||strcmp(actual,token))return scalar_bool(0);
  pid_t worker=getpid();pid_t watcher=fork();if(watcher<0)return scalar_bool(0);if(watcher==0){prctl(PR_SET_PDEATHSIG,SIGKILL);if(getppid()!=worker)_exit(0);for(;;){char current[128];if(getppid()!=worker)_exit(0);if(read_start_token(expected,current,sizeof(current))||strcmp(current,token)){kill(-getpgrp(),SIGKILL);_exit(191);}usleep(20000);}}
  return scalar_bool(1);
#else
  return scalar_bool(0);
#endif
}
SEXP saui_process_start_token(SEXP pid_s){char token[128];if(read_start_token((pid_t)asInteger(pid_s),token,sizeof(token)))return R_NilValue;return mkString(token);}

SEXP saui_terminate_process(SEXP pid_s, SEXP token_s, SEXP timeout_s) {
#ifdef __linux__
  pid_t pid=(pid_t)asInteger(pid_s);const char *token=one_string(token_s);int timeout=asInteger(timeout_s);char actual[128];
  if(pid<1||timeout<0||timeout>5000||read_start_token(pid,actual,sizeof(actual))||strcmp(actual,token))return scalar_chr("changed");
  if(kill(pid,SIGTERM)&&errno!=ESRCH)return scalar_chr("io_error");
  int elapsed=0,status=0;
  while(elapsed<timeout){pid_t w=waitpid(pid,&status,WNOHANG);if(w==pid)return scalar_chr("ok");if(kill(pid,0)&&errno==ESRCH){waitpid(pid,&status,WNOHANG);return scalar_chr("ok");}usleep(10000);elapsed+=10;}
  if(kill(pid,SIGKILL)&&errno!=ESRCH)return scalar_chr("io_error");
  for(int i=0;i<100;i++){pid_t w=waitpid(pid,&status,WNOHANG);if(w==pid)return scalar_chr("ok");if(kill(pid,0)&&errno==ESRCH){waitpid(pid,&status,WNOHANG);return scalar_chr("ok");}usleep(10000);}
  return scalar_chr("timeout");
#else
  return scalar_chr("unsupported");
#endif
}

SEXP saui_monotonic_ns(void){struct timespec ts;if(clock_gettime(CLOCK_MONOTONIC,&ts))return ScalarReal(NA_REAL);return ScalarReal((double)ts.tv_sec*1000000000.0+(double)ts.tv_nsec);}

static int append_text(char *buf,size_t cap,size_t *used,const char *text){size_t n=strlen(text);if(*used+n>=cap)return -1;memcpy(buf+*used,text,n);*used+=n;buf[*used]='\0';return 0;}
SEXP saui_encode_validated_rows(SEXP rows){if(TYPEOF(rows)!=VECSXP)error("rows must be list");R_xlen_t count=XLENGTH(rows);SEXP out=PROTECT(allocVector(STRSXP,count));
  for(R_xlen_t i=0;i<count;i++){SEXP row=VECTOR_ELT(rows,i);char buf[16384];size_t used=0;buf[0]='\0';int ok=TYPEOF(row)==VECSXP&&XLENGTH(row)==4;SEXP event=R_NilValue,ts=R_NilValue,metrics=R_NilValue;
    if(ok){event=VECTOR_ELT(row,1);ts=VECTOR_ELT(row,2);metrics=VECTOR_ELT(row,3);ok=TYPEOF(event)==STRSXP&&XLENGTH(event)==1&&STRING_ELT(event,0)!=NA_STRING&&TYPEOF(metrics)==VECSXP;}
    if(ok)ok=!append_text(buf,sizeof(buf),&used,"{\"schema\":1,\"event\":\"")&&!append_text(buf,sizeof(buf),&used,CHAR(STRING_ELT(event,0)))&&!append_text(buf,sizeof(buf),&used,"\",\"ts\":");
    if(ok){double value=asReal(ts);char num[64];if(!R_FINITE(value)||value<0||value!=floor(value))ok=0;else{snprintf(num,sizeof(num),"%.0f",value);ok=!append_text(buf,sizeof(buf),&used,num);}}
    if(ok)ok=!append_text(buf,sizeof(buf),&used,",\"metrics\":{");SEXP names=getAttrib(metrics,R_NamesSymbol);if(ok&&XLENGTH(metrics)>0&&(TYPEOF(names)!=STRSXP||XLENGTH(names)!=XLENGTH(metrics)))ok=0;
    for(R_xlen_t j=0;ok&&j<XLENGTH(metrics);j++){if(j)ok=!append_text(buf,sizeof(buf),&used,",");if(!ok)break;const char *name=CHAR(STRING_ELT(names,j));ok=!append_text(buf,sizeof(buf),&used,"\"")&&!append_text(buf,sizeof(buf),&used,name)&&!append_text(buf,sizeof(buf),&used,"\":");if(!ok)break;SEXP value=VECTOR_ELT(metrics,j);if(TYPEOF(value)==STRSXP&&XLENGTH(value)==1&&STRING_ELT(value,0)!=NA_STRING){const char *v=CHAR(STRING_ELT(value,0));for(const char *q=v;*q;q++)if(!( (*q>='a'&&*q<='z')||(*q>='A'&&*q<='Z')||(*q>='0'&&*q<='9')||*q=='_'||*q=='-' )){ok=0;break;}if(ok)ok=!append_text(buf,sizeof(buf),&used,"\"")&&!append_text(buf,sizeof(buf),&used,v)&&!append_text(buf,sizeof(buf),&used,"\"");}else{double v=asReal(value);char num[64];if(!R_FINITE(v)||v<0||v!=floor(v))ok=0;else{snprintf(num,sizeof(num),"%.0f",v);ok=!append_text(buf,sizeof(buf),&used,num);}}}
    if(ok)ok=!append_text(buf,sizeof(buf),&used,"}}\n");SET_STRING_ELT(out,i,ok?mkCharCE(buf,CE_UTF8):NA_STRING);
  }UNPROTECT(1);return out;
}

SEXP saui_fs_create_at(SEXP root_s,SEXP tmp_s,SEXP final_s){saui_handle *root=get_handle(root_s);const char *tmp=one_string(tmp_s),*final=one_string(final_s);if(!safe_basename(tmp)||!safe_basename(final))return R_NilValue;int fd=openat(root->fd,tmp,O_WRONLY|O_APPEND|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return R_NilValue;if(fchmod(fd,0600)||fsync(fd)||publish_noreplace_at(root->fd,tmp,root->fd,final)||fsync(root->fd)){int saved=errno;close(fd);unlinkat(root->fd,tmp,0);errno=saved;return R_NilValue;}return make_handle(fd,NULL);}
SEXP saui_fs_open_append_at(SEXP root_s,SEXP name_s){saui_handle *root=get_handle(root_s);const char *name=one_string(name_s);if(!safe_basename(name))return R_NilValue;struct stat a,b;if(fstatat(root->fd,name,&a,AT_SYMLINK_NOFOLLOW)||!S_ISREG(a.st_mode)||a.st_nlink!=1||a.st_uid!=geteuid())return R_NilValue;int fd=openat(root->fd,name,O_WRONLY|O_APPEND|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return R_NilValue;if(fstat(fd,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||b.st_nlink!=1){close(fd);return R_NilValue;}return make_handle(fd,NULL);}
SEXP saui_file_write(SEXP handle_s,SEXP raw_s,SEXP sync_s){saui_handle *h=get_handle(handle_s);if(TYPEOF(raw_s)!=RAWSXP)return scalar_bool(0);const unsigned char *p=RAW(raw_s);R_xlen_t left=XLENGTH(raw_s);while(left>0){ssize_t n=write(h->fd,p,(size_t)(left>SSIZE_MAX?SSIZE_MAX:left));if(n<=0)return scalar_bool(0);p+=n;left-=n;}if(asLogical(sync_s)==1&&fsync(h->fd))return scalar_bool(0);return scalar_bool(1);}
SEXP saui_file_close(SEXP handle_s){if(TYPEOF(handle_s)!=EXTPTRSXP)return scalar_bool(0);saui_handle *h=(saui_handle*)R_ExternalPtrAddr(handle_s);if(!h)return scalar_bool(0);handle_finalizer(handle_s);return scalar_bool(1);}
SEXP saui_fs_read_at(SEXP root_s,SEXP name_s,SEXP max_s){saui_handle *root=get_handle(root_s);const char *name=one_string(name_s);double maxd=asReal(max_s);if(!safe_basename(name)||!R_FINITE(maxd)||maxd<0||maxd>64*1024*1024)return R_NilValue;struct stat a,b;if(fstatat(root->fd,name,&a,AT_SYMLINK_NOFOLLOW)||!S_ISREG(a.st_mode)||a.st_nlink!=1||a.st_size>maxd)return R_NilValue;int fd=openat(root->fd,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return R_NilValue;if(fstat(fd,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||b.st_nlink!=1){close(fd);return R_NilValue;}SEXP out=PROTECT(allocVector(RAWSXP,b.st_size));size_t got=0;while(got<(size_t)b.st_size){ssize_t n=read(fd,RAW(out)+got,(size_t)b.st_size-got);if(n<=0){close(fd);UNPROTECT(1);return R_NilValue;}got+=(size_t)n;}close(fd);UNPROTECT(1);return out;}

SEXP saui_fs_atomic_replace_at(SEXP root_s,SEXP tmp_s,SEXP final_s,SEXP raw_s){saui_handle *root=get_handle(root_s);const char *tmp=one_string(tmp_s),*final=one_string(final_s);if(!safe_basename(tmp)||!safe_basename(final)||TYPEOF(raw_s)!=RAWSXP)return scalar_chr("invalid");struct stat before,check;int exists=fstatat(root->fd,final,&before,AT_SYMLINK_NOFOLLOW)==0;if(exists&&(!S_ISREG(before.st_mode)||before.st_nlink!=1||before.st_uid!=geteuid()))return scalar_chr("unsafe");if(!exists&&errno!=ENOENT)return scalar_chr("io_error");int fd=openat(root->fd,tmp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return scalar_chr(errno==EEXIST?"existing":"io_error");const unsigned char *p=RAW(raw_s);R_xlen_t left=XLENGTH(raw_s);int ok=1;while(left>0){ssize_t n=write(fd,p,(size_t)(left>SSIZE_MAX?SSIZE_MAX:left));if(n<=0){ok=0;break;}p+=n;left-=n;}if(ok&&(fchmod(fd,0600)||fsync(fd)))ok=0;close(fd);if(!ok){unlinkat(root->fd,tmp,0);return scalar_chr("io_error");}if(exists){if(fstatat(root->fd,final,&check,AT_SYMLINK_NOFOLLOW)||before.st_dev!=check.st_dev||before.st_ino!=check.st_ino||check.st_nlink!=1){unlinkat(root->fd,tmp,0);return scalar_chr("changed");}if(renameat(root->fd,tmp,root->fd,final)){unlinkat(root->fd,tmp,0);return scalar_chr("io_error");}}else if(publish_noreplace_at(root->fd,tmp,root->fd,final)){int e=errno;unlinkat(root->fd,tmp,0);return scalar_chr(e==EEXIST?"existing":"io_error");}if(fsync(root->fd))return scalar_chr("io_error");return scalar_chr("ok");}

SEXP saui_fs_open_read_at(SEXP root_s,SEXP name_s){saui_handle *root=get_handle(root_s);const char *name=one_string(name_s);if(!safe_basename(name))return R_NilValue;struct stat a,b;if(fstatat(root->fd,name,&a,AT_SYMLINK_NOFOLLOW)||!S_ISREG(a.st_mode)||a.st_nlink!=1||a.st_uid!=geteuid())return R_NilValue;int fd=openat(root->fd,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return R_NilValue;if(fstat(fd,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||b.st_nlink!=1){close(fd);return R_NilValue;}return make_handle(fd,NULL);}
SEXP saui_file_read_all(SEXP handle_s,SEXP max_s){saui_handle *h=get_handle(handle_s);double maxd=asReal(max_s);struct stat st;if(!R_FINITE(maxd)||maxd<0||maxd>64*1024*1024||fstat(h->fd,&st)||!S_ISREG(st.st_mode)||st.st_size>maxd)return R_NilValue;if(lseek(h->fd,0,SEEK_SET)<0)return R_NilValue;SEXP out=PROTECT(allocVector(RAWSXP,st.st_size));size_t got=0;while(got<(size_t)st.st_size){ssize_t n=read(h->fd,RAW(out)+got,(size_t)st.st_size-got);if(n<=0){UNPROTECT(1);return R_NilValue;}got+=(size_t)n;}UNPROTECT(1);return out;}
static uint32_t crc32_bytes(const unsigned char *data,size_t n){uint32_t crc=0xffffffffu;for(size_t i=0;i<n;i++){crc^=data[i];for(int j=0;j<8;j++)crc=(crc>>1)^((crc&1)?0xedb88320u:0);}return crc^0xffffffffu;}
SEXP saui_crc32(SEXP raw_s){if(TYPEOF(raw_s)!=RAWSXP)return ScalarReal(NA_REAL);return ScalarReal((double)crc32_bytes(RAW(raw_s),(size_t)XLENGTH(raw_s)));}
static uint16_t rd16(const unsigned char *p){return(uint16_t)(p[0]|((uint16_t)p[1]<<8));}static uint32_t rd32(const unsigned char *p){return(uint32_t)(p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24));}
static int safe_zip_name(const unsigned char *p,size_t n){if(n==13&&!memcmp(p,"manifest.json",13))return 1;if(n==15&&!memcmp(p,"logs/",5)&&!memcmp(p+9,".jsonl",6)){for(int i=5;i<9;i++)if(p[i]<'0'||p[i]>'9')return 0;return 1;}return 0;}
SEXP saui_verify_store_zip(SEXP raw_s){if(TYPEOF(raw_s)!=RAWSXP)return scalar_bool(0);const unsigned char *d=RAW(raw_s);size_t n=(size_t)XLENGTH(raw_s);if(n<22)return scalar_bool(0);size_t e=n-22;if(rd32(d+e)!=0x06054b50u||rd16(d+e+4)||rd16(d+e+6)||rd16(d+e+20))return scalar_bool(0);uint16_t entries=rd16(d+e+10);if(entries!=rd16(d+e+8)||entries<1||entries>129)return scalar_bool(0);uint32_t cdsize=rd32(d+e+12),cdoff=rd32(d+e+16);if((uint64_t)cdoff+cdsize!=e)return scalar_bool(0);size_t pos=cdoff;char seen[129][32];size_t seen_n=0;
 for(uint16_t i=0;i<entries;i++){if(pos+46>e||rd32(d+pos)!=0x02014b50u||rd16(d+pos+8)||rd16(d+pos+10)!=0||rd16(d+pos+30)||rd16(d+pos+32))return scalar_bool(0);uint16_t nl=rd16(d+pos+28),xl=rd16(d+pos+30),cl=rd16(d+pos+32);if(nl<1||nl>=32||pos+46+nl+xl+cl>e||!safe_zip_name(d+pos+46,nl))return scalar_bool(0);char name[32];memcpy(name,d+pos+46,nl);name[nl]='\0';for(size_t k=0;k<seen_n;k++)if(!strcmp(name,seen[k]))return scalar_bool(0);strcpy(seen[seen_n++],name);uint32_t crc=rd32(d+pos+16),cs=rd32(d+pos+20),us=rd32(d+pos+24),lo=rd32(d+pos+42);if(cs!=us||lo+30>cdoff||rd32(d+lo)!=0x04034b50u||rd16(d+lo+6)||rd16(d+lo+8)!=0)return scalar_bool(0);uint16_t lnl=rd16(d+lo+26),lxl=rd16(d+lo+28);if(lnl!=nl||lxl||lo+30+lnl+(uint64_t)us>cdoff||memcmp(d+lo+30,d+pos+46,nl)||rd32(d+lo+14)!=crc||rd32(d+lo+18)!=us||rd32(d+lo+22)!=us||crc32_bytes(d+lo+30+lnl,us)!=crc)return scalar_bool(0);pos+=46+nl+xl+cl;}
 if(pos!=e||strcmp(seen[0],"manifest.json"))return scalar_bool(0);return scalar_bool(1);}

SEXP saui_set_subreaper(void){
#ifdef __linux__
 return scalar_bool(prctl(PR_SET_CHILD_SUBREAPER,1)==0);
#else
 return scalar_bool(0);
#endif
}
SEXP saui_reap_children(SEXP timeout_s){int timeout=asInteger(timeout_s);if(timeout<0||timeout>5000)return ScalarInteger(-1);int reaped=0,elapsed=0,status;while(elapsed<=timeout){for(;;){pid_t p=waitpid(-1,&status,WNOHANG);if(p>0){reaped++;continue;}if(p<0&&errno==ECHILD)return ScalarInteger(reaped);break;}usleep(10000);elapsed+=10;}return ScalarInteger(reaped);}

SEXP saui_file_sync(SEXP handle_s){saui_handle *h=get_handle(handle_s);return scalar_bool(fsync(h->fd)==0);}


SEXP saui_file_stat(SEXP handle_s){saui_handle *h=get_handle(handle_s);struct stat st;if(fstat(h->fd,&st))return R_NilValue;return stat_result(&st);}

SEXP saui_process_probe(SEXP pid_s){
  const char *names[]={"category","startToken"};SEXP out=PROTECT(named_list(2,names));
#ifdef __linux__
  pid_t pid=(pid_t)asInteger(pid_s);char path[64],buf[4096];
  if(pid<1){SET_VECTOR_ELT(out,0,scalar_chr("unknown"));SET_VECTOR_ELT(out,1,R_NilValue);UNPROTECT(1);return out;}
  snprintf(path,sizeof(path),"/proc/%ld/stat",(long)pid);int fd=open(path,O_RDONLY|O_CLOEXEC);
  if(fd<0){SET_VECTOR_ELT(out,0,scalar_chr(errno==ENOENT?"dead":"unknown"));SET_VECTOR_ELT(out,1,R_NilValue);UNPROTECT(1);return out;}
  ssize_t n=read(fd,buf,sizeof(buf)-1);int saved=errno;close(fd);errno=saved;
  if(n<=0){SET_VECTOR_ELT(out,0,scalar_chr("unknown"));SET_VECTOR_ELT(out,1,R_NilValue);UNPROTECT(1);return out;}
  buf[n]='\0';char *end=strrchr(buf,')');if(!end){SET_VECTOR_ELT(out,0,scalar_chr("unknown"));SET_VECTOR_ELT(out,1,R_NilValue);UNPROTECT(1);return out;}
  char *p=end+1;while(*p==' ')++p;int field=3;char *save=NULL;char *tok=strtok_r(p," ",&save);while(tok&&field<22){tok=strtok_r(NULL," ",&save);++field;}
  if(!tok||field!=22){SET_VECTOR_ELT(out,0,scalar_chr("unknown"));SET_VECTOR_ELT(out,1,R_NilValue);}else{SET_VECTOR_ELT(out,0,scalar_chr("live"));SET_VECTOR_ELT(out,1,scalar_chr(tok));}
#else
  SET_VECTOR_ELT(out,0,scalar_chr("unknown"));SET_VECTOR_ELT(out,1,R_NilValue);
#endif
  UNPROTECT(1);return out;
}

SEXP saui_fs_quarantine_at(SEXP root_s,SEXP name_s,SEXP quarantine_s,SEXP dev_s,SEXP ino_s){
  saui_handle *root=get_handle(root_s);const char *name=one_string(name_s),*q=one_string(quarantine_s);
  if(!safe_basename(name)||!safe_basename(q))return scalar_chr("invalid");
  struct stat st;int fd=openat(root->fd,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return scalar_chr(errno==ENOENT?"missing":"unsafe");
  int ok=!fstat(fd,&st)&&S_ISREG(st.st_mode)&&st.st_nlink==1&&(double)st.st_dev==asReal(dev_s)&&(double)st.st_ino==asReal(ino_s);close(fd);
  if(!ok)return scalar_chr("changed");
  if(publish_noreplace_at(root->fd,name,root->fd,q))return scalar_chr(errno==EEXIST?"existing":"io_error");
  if(fsync(root->fd))return scalar_chr("io_error");return scalar_chr("ok");
}

static uint32_t sha_rotr(uint32_t x,int n){return(x>>n)|(x<<(32-n));}
static void sha256_bytes(const unsigned char *data,size_t len,unsigned char out[32]){
  static const uint32_t k[64]={
    0x428a2f98u,0x71374491u,0xb5c0fbcfu,0xe9b5dba5u,0x3956c25bu,0x59f111f1u,0x923f82a4u,0xab1c5ed5u,
    0xd807aa98u,0x12835b01u,0x243185beu,0x550c7dc3u,0x72be5d74u,0x80deb1feu,0x9bdc06a7u,0xc19bf174u,
    0xe49b69c1u,0xefbe4786u,0x0fc19dc6u,0x240ca1ccu,0x2de92c6fu,0x4a7484aau,0x5cb0a9dcu,0x76f988dau,
    0x983e5152u,0xa831c66du,0xb00327c8u,0xbf597fc7u,0xc6e00bf3u,0xd5a79147u,0x06ca6351u,0x14292967u,
    0x27b70a85u,0x2e1b2138u,0x4d2c6dfcu,0x53380d13u,0x650a7354u,0x766a0abbu,0x81c2c92eu,0x92722c85u,
    0xa2bfe8a1u,0xa81a664bu,0xc24b8b70u,0xc76c51a3u,0xd192e819u,0xd6990624u,0xf40e3585u,0x106aa070u,
    0x19a4c116u,0x1e376c08u,0x2748774cu,0x34b0bcb5u,0x391c0cb3u,0x4ed8aa4au,0x5b9cca4fu,0x682e6ff3u,
    0x748f82eeu,0x78a5636fu,0x84c87814u,0x8cc70208u,0x90befffau,0xa4506cebu,0xbef9a3f7u,0xc67178f2u};
  uint32_t h[8]={0x6a09e667u,0xbb67ae85u,0x3c6ef372u,0xa54ff53au,0x510e527fu,0x9b05688cu,0x1f83d9abu,0x5be0cd19u};
  uint64_t bits=(uint64_t)len*8u;size_t total=((len+9+63)/64)*64;unsigned char *msg=(unsigned char*)calloc(total,1);if(!msg){memset(out,0,32);return;}memcpy(msg,data,len);msg[len]=0x80;for(int i=0;i<8;i++)msg[total-1-i]=(unsigned char)(bits>>(8*i));
  for(size_t off=0;off<total;off+=64){uint32_t w[64];for(int i=0;i<16;i++)w[i]=((uint32_t)msg[off+4*i]<<24)|((uint32_t)msg[off+4*i+1]<<16)|((uint32_t)msg[off+4*i+2]<<8)|msg[off+4*i+3];for(int i=16;i<64;i++){uint32_t s0=sha_rotr(w[i-15],7)^sha_rotr(w[i-15],18)^(w[i-15]>>3),s1=sha_rotr(w[i-2],17)^sha_rotr(w[i-2],19)^(w[i-2]>>10);w[i]=w[i-16]+s0+w[i-7]+s1;}uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];for(int i=0;i<64;i++){uint32_t s1=sha_rotr(e,6)^sha_rotr(e,11)^sha_rotr(e,25),ch=(e&f)^((~e)&g),t1=hh+s1+ch+k[i]+w[i],s0=sha_rotr(a,2)^sha_rotr(a,13)^sha_rotr(a,22),maj=(a&b)^(a&c)^(b&c),t2=s0+maj;hh=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;}h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=hh;}
  free(msg);for(int i=0;i<8;i++){out[4*i]=(unsigned char)(h[i]>>24);out[4*i+1]=(unsigned char)(h[i]>>16);out[4*i+2]=(unsigned char)(h[i]>>8);out[4*i+3]=(unsigned char)h[i];}
}
SEXP saui_sha256(SEXP raw_s){if(TYPEOF(raw_s)!=RAWSXP)return R_NilValue;unsigned char hash[32];sha256_bytes(RAW(raw_s),(size_t)XLENGTH(raw_s),hash);char hex[65];static const char digits[]="0123456789abcdef";for(int i=0;i<32;i++){hex[2*i]=digits[hash[i]>>4];hex[2*i+1]=digits[hash[i]&15];}hex[64]='\0';return scalar_chr(hex);}

SEXP saui_store_zip_entries(SEXP raw_s){
  if(TYPEOF(raw_s)!=RAWSXP)return R_NilValue;SEXP valid=PROTECT(saui_verify_store_zip(raw_s));if(asLogical(valid)!=1){UNPROTECT(1);return R_NilValue;}
  const unsigned char *d=RAW(raw_s);size_t n=(size_t)XLENGTH(raw_s),e=n-22;uint16_t entries=rd16(d+e+10);uint32_t cdoff=rd32(d+e+16);size_t pos=cdoff;
  SEXP out=PROTECT(allocVector(VECSXP,entries));SEXP names=PROTECT(allocVector(STRSXP,entries));
  for(uint16_t i=0;i<entries;i++){uint16_t nl=rd16(d+pos+28);uint32_t us=rd32(d+pos+24),lo=rd32(d+pos+42);uint16_t lnl=rd16(d+lo+26);SEXP bytes=PROTECT(allocVector(RAWSXP,us));memcpy(RAW(bytes),d+lo+30+lnl,us);SET_VECTOR_ELT(out,i,bytes);UNPROTECT(1);char name[32];memcpy(name,d+pos+46,nl);name[nl]='\0';SET_STRING_ELT(names,i,mkCharCE(name,CE_UTF8));pos+=46+nl;}
  setAttrib(out,R_NamesSymbol,names);UNPROTECT(3);return out;
}
