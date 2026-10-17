// SPDX-License-Identifier: Apache-2.0
#include <jni.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

extern char* ExVPNValidate(char*);
extern char* ExVPNStart(char*, char*, int, int*, int, char*);
extern void ExVPNStop(void);
extern void ExVPNCancel(void);
extern char* ExVPNHealth(void);
extern char* ExVPNStats(void);

static JavaVM* jvm;
static jobject service;
static jmethodID protect_method;
static jmethodID owner_method;
static pthread_mutex_t refs = PTHREAD_MUTEX_INITIALIZER;

JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void* reserved) { jvm=vm; return JNI_VERSION_1_6; }

static JNIEnv* callback_env(int* attached) {
 JNIEnv* env=NULL;*attached=0;
 if ((*jvm)->GetEnv(jvm,(void**)&env,JNI_VERSION_1_6)==JNI_EDETACHED) {
   if ((*jvm)->AttachCurrentThread(jvm,&env,NULL)!=JNI_OK)return NULL;*attached=1;
 }
 return env;
}
static jobject current_service(JNIEnv* env) {
 pthread_mutex_lock(&refs);jobject result=service?(*env)->NewLocalRef(env,service):NULL;pthread_mutex_unlock(&refs);return result;
}
int exvpn_protect(int fd) {
 int attached;JNIEnv* env=callback_env(&attached);if(!env)return 0;
 jobject target=current_service(env);int result=0;
 if(target){result=(*env)->CallBooleanMethod(env,target,protect_method,fd)==JNI_TRUE;(*env)->DeleteLocalRef(env,target);}
 if((*env)->ExceptionCheck(env)){(*env)->ExceptionClear(env);result=0;}
 if(attached)(*jvm)->DetachCurrentThread(jvm);return result;
}
int exvpn_owner(int protocol,const char* localIP,int localPort,const char* remoteIP,int remotePort) {
 int attached;JNIEnv* env=callback_env(&attached);if(!env)return -1;
 jobject target=current_service(env);int result=-1;
 if(target){jstring local=(*env)->NewStringUTF(env,localIP),remote=(*env)->NewStringUTF(env,remoteIP);
 result=(*env)->CallIntMethod(env,target,owner_method,protocol,local,localPort,remote,remotePort);
 (*env)->DeleteLocalRef(env,local);(*env)->DeleteLocalRef(env,remote);(*env)->DeleteLocalRef(env,target);}
 if((*env)->ExceptionCheck(env)){(*env)->ExceptionClear(env);result=-1;}
 if(attached)(*jvm)->DetachCurrentThread(jvm);return result;
}
static jstring result_string(JNIEnv* env,char* value){jstring result=(*env)->NewStringUTF(env,value);free(value);return result;}
static char* profile_bytes(JNIEnv* env,jbyteArray profile){
 jsize length=(*env)->GetArrayLength(env,profile);if(length<1 || length>1048576)return NULL;
 char* result=malloc((size_t)length+1);if(!result)return NULL;
 (*env)->GetByteArrayRegion(env,profile,0,length,(jbyte*)result);result[length]=0;
 if(memchr(result,0,length)){free(result);return NULL;}return result;
}

JNIEXPORT jstring JNICALL Java_ru_exvpn_exvpn_NativeCore_validate(JNIEnv* env,jobject self,jbyteArray profile){
 char* raw=profile_bytes(env,profile);if(!raw)return (*env)->NewStringUTF(env,"profile_invalid_bytes");
 char* result=ExVPNValidate(raw);free(raw);return result_string(env,result);
}
JNIEXPORT jstring JNICALL Java_ru_exvpn_exvpn_NativeCore_start(JNIEnv* env,jobject self,jobject owner,jint fd,jbyteArray profile,jstring endpoint,jintArray exclusions,jstring routingMode){
 char* raw=profile_bytes(env,profile);if(!raw)return (*env)->NewStringUTF(env,"profile_invalid_bytes");
 pthread_mutex_lock(&refs);
 if(service){pthread_mutex_unlock(&refs);free(raw);return (*env)->NewStringUTF(env,"core_already_running");}
 jclass type=(*env)->GetObjectClass(env,owner);
 protect_method=(*env)->GetMethodID(env,type,"protectSocket","(I)Z");
 owner_method=(*env)->GetMethodID(env,type,"connectionOwner","(ILjava/lang/String;ILjava/lang/String;I)I");
 service=(*env)->NewGlobalRef(env,owner);(*env)->DeleteLocalRef(env,type);pthread_mutex_unlock(&refs);
 const char* ip=(*env)->GetStringUTFChars(env,endpoint,NULL);
 jint* uids=(*env)->GetIntArrayElements(env,exclusions,NULL);jsize count=(*env)->GetArrayLength(env,exclusions);
 const char* mode=(*env)->GetStringUTFChars(env,routingMode,NULL);
 char* result=ExVPNStart((char*)raw,(char*)ip,fd,(int*)uids,count,(char*)mode);
 (*env)->ReleaseStringUTFChars(env,routingMode,mode);
 (*env)->ReleaseIntArrayElements(env,exclusions,uids,JNI_ABORT);free(raw);(*env)->ReleaseStringUTFChars(env,endpoint,ip);
 if(result[0]){pthread_mutex_lock(&refs);(*env)->DeleteGlobalRef(env,service);service=NULL;pthread_mutex_unlock(&refs);}
 return result_string(env,result);
}
JNIEXPORT void JNICALL Java_ru_exvpn_exvpn_NativeCore_stop(JNIEnv* env,jobject self){
 ExVPNStop();pthread_mutex_lock(&refs);if(service)(*env)->DeleteGlobalRef(env,service);service=NULL;pthread_mutex_unlock(&refs);
}
JNIEXPORT void JNICALL Java_ru_exvpn_exvpn_NativeCore_cancel(JNIEnv* env,jobject self){ExVPNCancel();}
JNIEXPORT jstring JNICALL Java_ru_exvpn_exvpn_NativeCore_health(JNIEnv* env,jobject self){return result_string(env,ExVPNHealth());}
JNIEXPORT jstring JNICALL Java_ru_exvpn_exvpn_NativeCore_stats(JNIEnv* env,jobject self){return result_string(env,ExVPNStats());}
