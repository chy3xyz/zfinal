#include <libpq-fe.h>
#define ZF_INT2OID      21
#define ZF_INT4OID      23
#define ZF_INT8OID      20
#define ZF_BIGSERIALOID 20
#define ZF_FLOAT4OID    700
#define ZF_FLOAT8OID    701
#define ZF_BOOLOID      16
#define ZF_BYTEAOID     17
#define ZF_TEXTOID      25
#define ZF_VARCHAROID   1043
/* Types whose binary wire format is NOT their text form. Each of these needs
   an explicit decoder in readPgCell(); without one, result_format=1 hands
   back raw bytes that are not valid UTF-8. */
#define ZF_OIDOID         26
#define ZF_NAMEOID        19
#define ZF_JSONOID        114
#define ZF_BPCHAROID      1042
#define ZF_CIDROID        650
#define ZF_INETOID        869
#define ZF_DATEOID        1082
#define ZF_TIMEOID        1083
#define ZF_TIMESTAMPOID   1114
#define ZF_TIMESTAMPTZOID 1184
#define ZF_TIMETZOID      1266
#define ZF_NUMERICOID     1700
#define ZF_UUIDOID        2950
#define ZF_JSONBOID       3802
