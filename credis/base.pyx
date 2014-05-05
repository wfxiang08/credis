cdef bytes SYM_STAR = b'*'
cdef bytes SYM_DOLLAR = b'$'
cdef bytes SYM_CRLF = b'\r\n'
cdef bytes SYM_LF = b'\n'

from cpython.object cimport PyObject_Str
from cpython.tuple cimport PyTuple_New, PyTuple_SetItem
from cpython.ref cimport Py_INCREF

DEF CHAR_BIT = 8

cdef object int_to_decimal_string(Py_ssize_t n):
    # sizeof(long)*CHAR_BIT/3+6
    cdef char buf[32], *p, *bufend
    cdef unsigned long absn
    cdef char c = '0'
    p = bufend = buf + sizeof(buf)
    if n < 0:
        absn = 0UL - n
    else:
        absn = n
    while True:
        p -= 1
        p[0] = c + (absn % 10)
        absn /= 10
        if absn == 0:
            break
    if n < 0:
        p -= 1
        p[0] = '-'
    return p[:(bufend-p)]

import sys
import socket
from cStringIO import StringIO as BytesIO

try:
    import hiredis
except ImportError:
    USE_HIREDIS = False
    hiredis = None
else:
    USE_HIREDIS = True

class RedisProtocolError(Exception):
    pass

class RedisReplyError(Exception):
    pass

class ConnectionError(Exception):
    pass

class AuthenticationError(Exception):
    pass

class SocketBuffer(object):
    def __init__(self, socket, socket_read_size):
        self._sock = socket
        self.socket_read_size = socket_read_size
        self._buffer = BytesIO()
        # number of bytes written to the buffer from the socket
        self.bytes_written = 0
        # number of bytes read from the buffer
        self.bytes_read = 0

    @property
    def length(self):
        return self.bytes_written - self.bytes_read

    def _read_from_socket(self, length=None):
        socket_read_size = self.socket_read_size
        buf = self._buffer
        buf.seek(self.bytes_written)
        marker = 0

        try:
            while True:
                data = self._sock.recv(socket_read_size)
                # an empty string indicates the server shutdown the socket
                if isinstance(data, str) and len(data) == 0:
                    raise socket.error("Connection closed by remote server.")
                buf.write(data)
                data_length = len(data)
                self.bytes_written += data_length
                marker += data_length

                if length is not None and length > marker:
                    continue
                break
        except (socket.error, socket.timeout):
            e = sys.exc_info()[1]
            raise ConnectionError("Error while reading from socket: %s" %
                                  (e.args,))

    def read(self, length):
        length = length + 2  # make sure to read the \r\n terminator
        # make sure we've read enough data from the socket
        if length > self.length:
            self._read_from_socket(length - self.length)

        self._buffer.seek(self.bytes_read)
        data = self._buffer.read(length)
        self.bytes_read += len(data)

        # purge the buffer when we've consumed it all so it doesn't
        # grow forever
        if self.bytes_read == self.bytes_written:
            self.purge()

        return data[:-2]

    def readline(self):
        buf = self._buffer
        buf.seek(self.bytes_read)
        data = buf.readline()
        while not data.endswith(SYM_CRLF):
            # there's more data in the socket that we need
            self._read_from_socket()
            buf.seek(self.bytes_read)
            data = buf.readline()

        self.bytes_read += len(data)

        # purge the buffer when we've consumed it all so it doesn't
        # grow forever
        if self.bytes_read == self.bytes_written:
            self.purge()

        return data[:-2]

    def purge(self):
        self._buffer.seek(0)
        self._buffer.truncate()
        self.bytes_written = 0
        self.bytes_read = 0

    def close(self):
        self.purge()
        self._buffer.close()
        self._buffer = None
        self._sock = None

EXCEPTION_CLASSES = {
    'ERR': RedisReplyError,
    'EXECABORT': RedisReplyError,
    'LOADING': RedisReplyError,
    'NOSCRIPT': RedisReplyError,
}

def parse_error(response):
    "Parse an error response"
    error_code = response.split(' ')[0]
    if error_code in EXCEPTION_CLASSES:
        response = response[len(error_code) + 1:]
        return EXCEPTION_CLASSES[error_code](response)
    return RedisReplyError(response)

cdef class Connection(object):
    "Manages TCP communication to and from a Redis server"

    cdef object host
    cdef object port
    cdef object db
    cdef object password
    cdef object socket_timeout
    cdef object encoding
    cdef object encoding_errors
    cdef bint decode_responses
    cdef object path

    cdef public int socket_read_size
    cdef public object _sock
    cdef public object _reader
    cdef public object _buffer

    def __init__(self, host='localhost', port=6379, db=None, password=None,
                 socket_timeout=None, encoding='utf-8', path=None,
                 encoding_errors='strict', decode_responses=False,
                 ):
        self.host = host
        self.port = port
        self.db = db
        self.password = password
        self.socket_timeout = socket_timeout
        if encoding != 'utf-8':
            self.encoding = encoding
        else:
            self.encoding = None # default to use utf-8 encoding
        if encoding_errors != 'strict':
            self.encoding_errors = encoding_errors
        else:
            self.encoding_errors = None # default to strict
        self.decode_responses = decode_responses

        self.socket_read_size = 4096
        self._sock = None
        self._reader = None

    def __del__(self):
        try:
            self.disconnect()
        except:
            pass

    def connect(self):
        "Connects to the Redis server if not already connected"
        if self._sock:
            return

        try:
            sock = self._connect()
        except socket.error as e:
            raise ConnectionError(self._error_message(e))

        self._sock = sock

        if USE_HIREDIS:
            kwargs = {
                'protocolError': RedisProtocolError,
                'replyError': RedisReplyError,
            }
            if self.decode_responses:
                kwargs['encoding'] = self.encoding or 'utf-8'
            self._reader = hiredis.Reader(**kwargs)
        else:
            self._buffer = SocketBuffer(self._sock, self.socket_read_size)

        self._init_connection()

    cdef _connect(self):
        "Create a TCP/UNIX socket connection"
        if self.path is not None:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(self.path)
        else:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.connect((self.host, self.port))
        sock.settimeout(self.socket_timeout)
        return sock

    cdef _error_message(self, exception):
        # args for socket.error can either be (errno, "message")
        # or just "message"
        address = self.path is None and '(%s:%s)'%(self.host, self.port) \
                                    or self.path
        return "Error connecting to %s. %s." % \
            (address, exception.args)

    cdef _init_connection(self):
        "Initialize the connection, authenticate and select a database"

        # if a password is specified, authenticate
        if self.password is not None:
            self.send_command(('AUTH', self.password))
            if <basestring>self.read_response() != 'OK':
                raise AuthenticationError('Invalid Password')

        # if a database is specified, switch to it
        if self.db is not None:
            self.send_command(('SELECT', self.db))
            if <basestring>self.read_response() != 'OK':
                raise ConnectionError('Invalid Database')

    cpdef disconnect(self):
        "Disconnects from the Redis server"
        self._reader = None
        if self._sock is None:
            return
        try:
            self._sock.close()
        except socket.error:
            pass
        self._sock = None

    cpdef send_packed_command(self, command):
        "Send an already packed command to the Redis server"
        if not self._sock:
            self.connect()
        try:
            self._sock.sendall(command)
        except socket.error as e:
            self.disconnect()
            raise ConnectionError("Error while writing to socket. %s." %
                                  (e.args))
        except:
            self.disconnect()
            raise

    cpdef send_command(self, args):
        "Pack and send a command to the Redis server"
        self.send_packed_command(self._pack_command(args))

    cdef _read_response(self):
        response = self._reader.gets()
        while response is False:
            try:
                buffer = self._sock.recv(4096)
            except (socket.error, socket.timeout) as e:
                raise ConnectionError("Error while reading from socket: %s" %
                                      (e.args,))
            if not buffer:
                raise ConnectionError("Socket closed on remote end")
            self._reader.feed(buffer)
            # proactively, but not conclusively, check if more data is in the
            # buffer. if the data received doesn't end with \n, there's more.
            if not buffer.endswith(SYM_LF):
                continue
            response = self._reader.gets()
        return response

    def _pure_read_response(self):
        response = self._buffer.readline()
        if not response:
            raise ConnectionError("Socket closed on remote end")

        byte, response = response[0], response[1:]

        if byte not in ('-', '+', ':', '$', '*'):
            raise RedisProtocolError("Protocol Error: %s, %s" %
                                  (byte, response))

        # server returned an error
        if byte == '-':
            #response = nativestr(response)
            error = parse_error(response)
            # if the error is a ConnectionError, raise immediately so the user
            # is notified
            if isinstance(error, ConnectionError):
                raise error
            # otherwise, we're dealing with a ResponseError that might belong
            # inside a pipeline response. the connection's read_response()
            # and/or the pipeline's execute() will raise this error if
            # necessary, so just return the exception instance here.
            return error
        # single value
        elif byte == '+':
            pass
        # int value
        elif byte == ':':
            response = long(response)
        # bulk response
        elif byte == '$':
            length = int(response)
            if length == -1:
                return None
            response = self._buffer.read(length)
        # multi-bulk response
        elif byte == '*':
            length = int(response)
            if length == -1:
                return None
            response = [self._pure_read_response() for i in xrange(length)]
        if isinstance(response, bytes) and self.encoding:
            response = response.decode(self.encoding)
        return response

    cpdef read_response(self):
        "Read the response from a previously sent command"
        try:
            if USE_HIREDIS:
                return self._read_response()
            else:
                return self._pure_read_response()
        except:
            self.disconnect()
            raise

    cpdef read_n_response(self, int n):
        cdef result = PyTuple_New(n)
        cdef i
        cdef object o
        for i in range(n):
            o = self.read_response()
            Py_INCREF(o)
            PyTuple_SetItem(result, i, o)
        Py_INCREF(result)
        return result

    cdef bytes _encode(self, value):
        "Return a bytestring representation of the value"
        if isinstance(value, bytes):
            return value
        if isinstance(value, int):
            return int_to_decimal_string(<int>value)
        if isinstance(value, unicode):
            if self.encoding is None and self.encoding_errors is None:
                return (<unicode>value).encode('utf-8')
            else:
                return (<unicode>value).encode(self.encoding is not None or 'utf-8',
                                               self.encoding_errors is not None or 'strict')
        if not isinstance(value, basestring):
            return PyObject_Str(value)

    cdef _pack_command_list(self, list output, args):
        cdef bytes enc_value
        output.append(SYM_STAR)
        output.append(int_to_decimal_string(len(args)))
        output.append(SYM_CRLF)
        for value in args:
            enc_value = self._encode(value)
            output.append(SYM_DOLLAR)
            output.append(int_to_decimal_string(len(enc_value)))
            output.append(SYM_CRLF)
            output.append(enc_value)
            output.append(SYM_CRLF)

    cdef _pack_command(self, args):
        "Pack a series of arguments into a value Redis command"
        cdef list output = []
        self._pack_command_list(output, args)
        return b''.join(output)

    cdef _pack_pipeline_command(self, cmds):
        "Pack a series of arguments into a value Redis command"
        cdef list output = []
        cdef object args
        for args in cmds:
            self._pack_command_list(output, args)
        return b''.join(output)

    cpdef send_pipeline(self, cmds):
        self.send_packed_command(self._pack_pipeline_command(cmds))

    def execute(self, *args):
        self.send_command(args)
        reply = self.read_response()
        if isinstance(reply, RedisReplyError):
            raise reply
        return reply

    def execute_pipeline(self, *cmds):
        self.send_pipeline(cmds)
        return self.read_n_response(len(cmds))
