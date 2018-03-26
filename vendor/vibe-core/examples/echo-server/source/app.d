import vibe.core.core : runApplication;
import vibe.core.net : listenTCP;
import vibe.core.stream : pipe;

void main()
{
	listenTCP(7000, (conn) { pipe(conn, conn); });
	runApplication();
}
