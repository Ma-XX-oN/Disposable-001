/* RWF809: same POSIX source and fixture on native Linux ext4 and WSL2 ext4.
 * Not directly interchangeable with the Windows Win32/NT API measurements.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
enum { NFILES=8000, SIZE=871, SESSIONS=4, ROUNDS=5 };
static char paths[NFILES][240];
static const char *environment;
static double ticks(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t)) { perror("clock_gettime"); exit(2); }
  return (double)t.tv_sec*1000.0+(double)t.tv_nsec/1000000.0;
}
static void fatal(const char *message) {
  fprintf(stderr,"RWF809_POSIX_ERROR %s errno=%d (%s)\n",
          message,errno,strerror(errno));
  fflush(stderr);exit(2);
}
static unsigned char pattern(unsigned i,unsigned j) {
  return (unsigned char)((i*37U+j*13U+41U)&255U);
}
static void fixture(const char *root) {
  unsigned i,j;
  char dir[240];
  if (snprintf(dir,sizeof dir,"%s/rwf809-nt-files-0",root) >= (int)sizeof dir)
    fatal("fixture root path too long");
  if (mkdir(dir,0777)&&errno!=EEXIST) fatal("mkdir fixture");
  for (i=0;i<8;i++) {
    if (snprintf(dir,sizeof dir,"%s/rwf809-nt-files-0/folder-%02u",root,i) >= (int)sizeof dir)
      fatal("folder path too long");
    if (mkdir(dir,0777)&&errno!=EEXIST) fatal("mkdir folder");
  }
  for (i=0;i<NFILES;i++) {
    unsigned char bytes[SIZE];
    int fd;
    for (j=0;j<SIZE;j++) bytes[j]=pattern(i,j);
    if (snprintf(paths[i],sizeof paths[i],
      "%s/rwf809-nt-files-0/folder-%02u/tracked-%06u.bin",root,i/1000,i)
        >= (int)sizeof paths[i]) fatal("file path too long");
    fd=open(paths[i],O_WRONLY|O_CREAT|O_TRUNC,0666);
    if (fd<0) fatal("fixture open");
    if (write(fd,bytes,SIZE)!=SIZE) fatal("fixture write");
    if (close(fd)) fatal("fixture close");
  }
}
struct tally {
  double open_ms,read_ms,close_ms,meta_ms;
  unsigned operations;
  unsigned bytes;
  int failed;
};
struct arg {
  unsigned thread,threads,metadata,same;
  struct tally tally;
};
static void *worker(void *argptr) {
  struct arg *w=argptr;
  unsigned i;
  for(i=w->thread;i<NFILES;i+=w->threads) {
    unsigned idx=w->same?0:i,j;
    double a,b,c,d;
    struct stat st;
    unsigned char buffer[SIZE];
    int fd,n;
    if (w->metadata) {
      a=ticks();
      n=stat(paths[idx],&st);
      b=ticks();
      w->tally.meta_ms+=b-a;
      if(n || st.st_size!=SIZE) {w->tally.failed=1;return NULL;}
    } else {
      a=ticks();
      fd=open(paths[idx],O_RDONLY);
      b=ticks();
      w->tally.open_ms+=b-a;
      if(fd<0) {w->tally.failed=1;return NULL;}
      c=ticks();
      n=read(fd,buffer,SIZE);
      d=ticks();
      w->tally.read_ms+=d-c;
      if(n!=SIZE) {w->tally.failed=1;close(fd);return NULL;}
      for(j=0;j<SIZE;j++) {
        if(buffer[j]!=pattern(idx,j)) {w->tally.failed=1;close(fd);return NULL;}
      }
      c=ticks();
      n=close(fd);
      d=ticks();
      w->tally.close_ms+=d-c;
      if(n) {w->tally.failed=1;return NULL;}
    }
    w->tally.operations++;
    w->tally.bytes+=SIZE;
  }
  return NULL;
}
static void measure(unsigned session,unsigned round,unsigned metadata,
                    unsigned same,unsigned threads,int emit) {
  struct arg args[4]={0};
  pthread_t tids[4];
  struct tally total={0};
  unsigned i;
  double start=ticks(),end;
  for(i=0;i<threads;i++) {
    args[i].thread=i; args[i].threads=threads;
    args[i].metadata=metadata; args[i].same=same;
    if(pthread_create(&tids[i],NULL,worker,&args[i])) fatal("pthread_create");
  }
  for(i=0;i<threads;i++) {
    if(pthread_join(tids[i],NULL)) fatal("pthread_join");
  }
  end=ticks();
  for(i=0;i<threads;i++) {
    if(args[i].tally.failed) fatal("file operation or bytes verification failed");
    total.open_ms+=args[i].tally.open_ms;
    total.read_ms+=args[i].tally.read_ms;
    total.close_ms+=args[i].tally.close_ms;
    total.meta_ms+=args[i].tally.meta_ms;
    total.operations+=args[i].tally.operations;
    total.bytes+=args[i].tally.bytes;
  }
  if(total.operations!=NFILES || total.bytes!=NFILES*SIZE) fatal("invalid operations or bytes");
  if(emit) {
    printf("RWF809_POSIX_CSV %s,%s,%s,%u,%u,%u,%.6f,%.6f,%.6f,%.6f,%.6f,%u,%u\n",
       environment,metadata?"metadata":"all",same?"one":"distinct",
       threads,session,round,end-start,total.open_ms,total.read_ms,
       total.close_ms,total.meta_ms,total.operations,total.bytes);
  }
}
int main(int argc,char **argv) {
  unsigned s,m,p,t,r;
  struct stat st;
  if(argc!=3 || (strcmp(argv[1],"native-linux") && strcmp(argv[1],"wsl2"))) {
    fprintf(stderr,"Usage: bench {native-linux|wsl2} {verified-ext4-directory}\n"); return 2;
  }
  environment=argv[1];
  if(stat(argv[2],&st) || !S_ISDIR(st.st_mode)) fatal("benchmark directory");
  fixture(argv[2]);
  for(m=0;m<2;m++) for(p=0;p<2;p++) for(t=0;t<2;t++)
    measure(0,0,m,p,t?4:1,0);
  puts("RWF809_POSIX_HEADER env,mode,paths,threads,session,round,wall_ms,open_ms,read_ms,close_ms,meta_ms,operations,bytes");
  for(s=1;s<=SESSIONS;s++) {
    for(m=0;m<2;m++) for(p=0;p<2;p++) for(t=0;t<2;t++)
      for(r=0;r<ROUNDS;r++) measure(s,r,m,p,t?4:1,1);
    printf("RWF809_POSIX_SESSION_PASS env=%s session=%u\n",environment,s);
  }
  puts("RWF809_POSIX_PASS 160 measured rows 8000 operations 6968000 bytes each");
  return 0;
}
